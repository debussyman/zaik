defmodule Zaik.Intent.Parser do
  @moduledoc """
  LLM-backed structured intent parser for free-form Zaik chat.

  The parser classifies a natural-language message into a constrained JSON
  shape. It does not execute actions directly; `Zaik.ChatRouter` dispatches the
  parsed intent to trusted Elixir functions/commands.
  """

  @intents [
    "home_status",
    "home_sensor_status",
    "home_sensor_trend",
    "home_presence_status",
    "system_health",
    "watchdog_scan",
    "agent_chat",
    "llm_general_question",
    "unknown"
  ]

  @fields ["temperature", "humidity", "illuminance", "presence", "battery", "system", "all"]

  def config do
    app_config = Application.get_env(:zaik, :intent, [])

    %{
      enabled: env_bool("ZAIK_INTENT_ENABLED", Keyword.get(app_config, :enabled, true)),
      provider: Keyword.get(app_config, :provider, :ollama),
      model: System.get_env("ZAIK_INTENT_MODEL") || Keyword.get(app_config, :model, "qwen3:4b"),
      num_ctx: env_integer("ZAIK_INTENT_NUM_CTX") || Keyword.get(app_config, :num_ctx, 2048),
      num_predict:
        env_integer("ZAIK_INTENT_NUM_PREDICT") || Keyword.get(app_config, :num_predict, 160),
      timeout_ms:
        env_integer("ZAIK_INTENT_TIMEOUT_MS") || Keyword.get(app_config, :timeout_ms, 30_000),
      keep_alive:
        System.get_env("ZAIK_INTENT_KEEP_ALIVE") || Keyword.get(app_config, :keep_alive, "30m"),
      temperature:
        env_float("ZAIK_INTENT_TEMPERATURE") || Keyword.get(app_config, :temperature, 0.0),
      confidence_threshold:
        env_float("ZAIK_INTENT_CONFIDENCE_THRESHOLD") ||
          Keyword.get(app_config, :confidence_threshold, 0.4)
    }
  end

  def parse(message, opts \\ []) when is_binary(message) do
    cfg = Map.merge(config(), Map.new(opts))
    client = Keyword.get(opts, :client, Zaik.LLM.OllamaClient)

    if cfg.enabled do
      messages = [
        %{role: "system", content: system_prompt()},
        %{role: "user", content: message}
      ]

      with {:ok, result} <-
             client.chat("",
               messages: messages,
               model: cfg.model,
               num_ctx: cfg.num_ctx,
               num_predict: cfg.num_predict,
               temperature: cfg.temperature,
               keep_alive: cfg.keep_alive,
               format: "json",
               think: false,
               timeout_ms: cfg.timeout_ms,
               purpose: :intent_parser
             ),
           {:ok, decoded} <- decode_intent(result.response),
           {:ok, normalized} <- normalize_intent(decoded) do
        {:ok, normalized}
      end
    else
      {:error, :disabled}
    end
  end

  def intents, do: @intents
  def fields, do: @fields

  defp system_prompt do
    """
    You are Zaik's intent parser for a personal home agent.
    Return ONLY valid JSON matching this schema:
    {
      "intent": one of #{inspect(@intents)},
      "device_query": string or null,
      "fields": array of strings chosen from #{inspect(@fields)},
      "time_window": string or null,
      "confidence": number from 0 to 1
    }

    Use device_query "lily" for Lily's room, Lily, her room, or the current Lily room sensor.
    Use null when no specific device is requested.
    Choose home_sensor_trend for getting warmer/cooler/brighter/darker/rising/falling/changed over time.
    Choose home_sensor_status for current sensor readings.
    Choose home_presence_status for occupancy, presence, motion, or whether anyone is there.
    Choose home_status for whole-home status.
    Choose system_health for Zaik/system health questions.
    Choose watchdog_scan for explicit watchdog scan requests.
    Choose agent_chat for conversational questions that require Zaik memory, previous conversations, recent messages, what users asked, tasks, failures, model fallback, AgentChat traces, or flexible analysis over home/ops data.
    Examples of agent_chat:
    - "what questions have we asked you recently?"
    - "what have I asked you today?"
    - "did you fall back to the bigger model recently?"
    - "what tasks failed recently?"
    Choose llm_general_question only for non-control general knowledge questions that do not require Zaik memory or operational/home data.
    Choose unknown when the request cannot be safely mapped.
    Do not answer the user. Only classify.
    """
    |> String.trim()
  end

  defp decode_intent(response) when is_binary(response) do
    response
    |> String.trim()
    |> strip_code_fence()
    |> Jason.decode()
  end

  defp strip_code_fence("```json" <> rest),
    do: rest |> String.trim() |> String.trim_trailing("```") |> String.trim()

  defp strip_code_fence("```" <> rest),
    do: rest |> String.trim() |> String.trim_trailing("```") |> String.trim()

  defp strip_code_fence(response), do: response

  defp normalize_intent(decoded) when is_map(decoded) do
    intent = decoded |> Map.get("intent", "unknown") |> normalize_string()

    if intent in @intents do
      {:ok,
       %{
         intent: String.to_atom(intent),
         device_query: normalize_optional_string(Map.get(decoded, "device_query")),
         fields: normalize_fields(Map.get(decoded, "fields", [])),
         time_window: normalize_optional_string(Map.get(decoded, "time_window")),
         confidence: normalize_confidence(Map.get(decoded, "confidence")),
         raw: decoded
       }}
    else
      {:ok,
       %{
         intent: :unknown,
         device_query: nil,
         fields: [],
         time_window: nil,
         confidence: 0.0,
         raw: decoded
       }}
    end
  end

  defp normalize_intent(_decoded), do: {:error, :invalid_intent_shape}

  defp normalize_string(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_string()

  defp normalize_string(_value), do: "unknown"

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_optional_string(value), do: value |> to_string() |> String.trim()

  defp normalize_fields(fields) when is_list(fields) do
    fields
    |> Enum.map(&normalize_string/1)
    |> Enum.filter(&(&1 in @fields))
    |> Enum.uniq()
  end

  defp normalize_fields(field) when is_binary(field), do: normalize_fields([field])
  defp normalize_fields(_fields), do: []

  defp normalize_confidence(value) when is_integer(value) or is_float(value),
    do: max(0.0, min(value / 1, 1.0))

  defp normalize_confidence(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> normalize_confidence(number)
      _ -> 0.0
    end
  end

  defp normalize_confidence(_value), do: 0.0

  defp env_bool(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> value |> String.downcase() |> then(&(&1 in ["1", "true", "yes", "on"]))
    end
  end

  defp env_integer(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> nil
        end
    end
  end

  defp env_float(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> nil
        end
    end
  end
end

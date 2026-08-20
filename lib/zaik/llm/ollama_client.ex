defmodule Zaik.LLM.OllamaClient do
  @moduledoc """
  Ollama provider for local LLM workloads.

  This module implements `Zaik.LLM.Provider` and keeps the historical
  `Zaik.LLM.OllamaClient` API for compatibility.
  """

  @behaviour Zaik.LLM.Provider

  @default_url "http://localhost:11434"
  @default_model "qwen3-coder:30b"
  @default_num_ctx 32_768
  @default_num_predict 512
  @default_keep_alive "30m"

  @impl true
  def chat(prompt, opts \\ []) when is_binary(prompt) do
    messages = Keyword.get(opts, :messages, [%{role: "user", content: prompt}])
    model = Keyword.get(opts, :model, config().default_model)

    payload =
      %{
        model: model,
        messages: messages,
        stream: false,
        keep_alive: Keyword.get(opts, :keep_alive, config().keep_alive),
        options: %{
          num_ctx: Keyword.get(opts, :num_ctx, config().num_ctx),
          num_predict: Keyword.get(opts, :num_predict, config().num_predict),
          temperature: Keyword.get(opts, :temperature, config().temperature)
        }
      }
      |> maybe_put(:format, Keyword.get(opts, :format))
      |> maybe_put(:think, Keyword.get(opts, :think))

    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, decoded} <-
             post_json("/api/chat", payload, Keyword.get(opts, :timeout_ms, config().timeout_ms)) do
        content = get_in(decoded, ["message", "content"])

        if is_binary(content) do
          {:ok,
           %{
             model: Map.get(decoded, "model", model),
             response: content,
             done: Map.get(decoded, "done"),
             raw: decoded
           }}
        else
          {:error, {:invalid_ollama_response, decoded}}
        end
      end

    Zaik.LLM.Telemetry.record_call(:chat, model, result, started, opts)
    result
  end

  @impl true
  def generate(prompt, opts \\ []) when is_binary(prompt) do
    model = Keyword.get(opts, :model, config().default_model)

    payload =
      %{
        model: model,
        prompt: prompt,
        stream: false,
        keep_alive: Keyword.get(opts, :keep_alive, config().keep_alive),
        options: %{
          num_ctx: Keyword.get(opts, :num_ctx, config().num_ctx),
          num_predict: Keyword.get(opts, :num_predict, config().num_predict),
          temperature: Keyword.get(opts, :temperature, config().temperature)
        }
      }
      |> maybe_put(:format, Keyword.get(opts, :format))
      |> maybe_put(:think, Keyword.get(opts, :think))

    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, decoded} <-
             post_json(
               "/api/generate",
               payload,
               Keyword.get(opts, :timeout_ms, config().timeout_ms)
             ) do
        response = Map.get(decoded, "response")

        if is_binary(response) do
          {:ok,
           %{
             model: Map.get(decoded, "model", model),
             response: response,
             done: Map.get(decoded, "done"),
             raw: decoded
           }}
        else
          {:error, {:invalid_ollama_response, decoded}}
        end
      end

    Zaik.LLM.Telemetry.record_call(:generate, model, result, started, opts)
    result
  end

  @impl true
  def config do
    app_config = Application.get_env(:zaik, :llm, [])

    %{
      provider: :ollama,
      ollama_url:
        System.get_env("ZAIK_OLLAMA_URL") || Keyword.get(app_config, :ollama_url, @default_url),
      default_model:
        System.get_env("ZAIK_LLM_MODEL") ||
          Keyword.get(app_config, :default_model, @default_model),
      num_ctx:
        env_integer("ZAIK_LLM_NUM_CTX") || Keyword.get(app_config, :num_ctx, @default_num_ctx),
      num_predict:
        env_integer("ZAIK_LLM_NUM_PREDICT") ||
          Keyword.get(app_config, :num_predict, @default_num_predict),
      timeout_ms:
        env_integer("ZAIK_LLM_TIMEOUT_MS") || Keyword.get(app_config, :timeout_ms, 180_000),
      keep_alive:
        System.get_env("ZAIK_LLM_KEEP_ALIVE") ||
          Keyword.get(app_config, :keep_alive, @default_keep_alive),
      temperature: env_float("ZAIK_LLM_TEMPERATURE") || Keyword.get(app_config, :temperature, 0.2)
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp post_json(path, payload, timeout) do
    Zaik.LLM.HTTP.post_json(config().ollama_url, path, payload, timeout)
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

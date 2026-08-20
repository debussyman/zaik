defmodule Zaik.LLM.LlamaCppClient do
  @moduledoc """
  llama.cpp / `llama-server` provider for Zaik.

  This client uses llama.cpp's OpenAI-compatible chat endpoint:

      POST /v1/chat/completions

  Start `llama-server` separately, for example:

      llama-server -m /path/to/model.gguf --host 127.0.0.1 --port 8080

  Then configure Zaik with:

      ZAIK_LLM_PROVIDER=llama_cpp
      ZAIK_LLAMA_CPP_URL=http://localhost:8080
      ZAIK_LLM_MODEL=qwen3.8:27b

  `num_ctx` is generally a server-startup setting for llama.cpp, so this client
  does not send it by default. `num_predict` maps to OpenAI `max_tokens`.
  """

  @behaviour Zaik.LLM.Provider

  @default_url "http://localhost:8080"
  @default_model "local-model"
  @default_num_predict 512

  @impl true
  def chat(prompt, opts \\ []) when is_binary(prompt) do
    messages = Keyword.get(opts, :messages, [%{role: "user", content: prompt}])
    model = Keyword.get(opts, :model, config().default_model)

    payload =
      %{
        model: model,
        messages: normalize_messages(messages),
        stream: false,
        temperature: Keyword.get(opts, :temperature, config().temperature),
        max_tokens: Keyword.get(opts, :num_predict, config().num_predict)
      }
      |> maybe_put_response_format(Keyword.get(opts, :format))
      |> maybe_put_extra_body(Keyword.get(opts, :llama_cpp_extra_body, []))

    started = System.monotonic_time(:millisecond)

    http_client = Keyword.get(opts, :http_client, Zaik.LLM.HTTP)

    result =
      with {:ok, decoded} <-
             http_client.post_json(
               config().base_url,
               "/v1/chat/completions",
               payload,
               Keyword.get(opts, :timeout_ms, config().timeout_ms)
             ) do
        content = get_in(decoded, ["choices", Access.at(0), "message", "content"])

        if is_binary(content) do
          {:ok,
           %{
             model: Map.get(decoded, "model", model),
             response: content,
             done: true,
             raw: decoded
           }}
        else
          {:error, {:invalid_llama_cpp_response, decoded}}
        end
      end

    Zaik.LLM.Telemetry.record_call(:chat, model, result, started, opts)
    result
  end

  @impl true
  def generate(prompt, opts \\ []) when is_binary(prompt) do
    chat(prompt, opts)
  end

  @impl true
  def config do
    app_config = Application.get_env(:zaik, :llama_cpp, [])
    llm_config = Application.get_env(:zaik, :llm, [])

    %{
      provider: :llama_cpp,
      base_url:
        System.get_env("ZAIK_LLAMA_CPP_URL") ||
          System.get_env("ZAIK_LLAMA_SERVER_URL") ||
          Keyword.get(app_config, :base_url, @default_url),
      default_model:
        System.get_env("ZAIK_LLAMA_CPP_MODEL") ||
          System.get_env("ZAIK_LLM_MODEL") ||
          Keyword.get(app_config, :default_model) ||
          Keyword.get(llm_config, :default_model, @default_model),
      num_predict:
        env_integer("ZAIK_LLAMA_CPP_NUM_PREDICT") ||
          env_integer("ZAIK_LLM_NUM_PREDICT") ||
          Keyword.get(app_config, :num_predict) ||
          Keyword.get(llm_config, :num_predict, @default_num_predict),
      timeout_ms:
        env_integer("ZAIK_LLAMA_CPP_TIMEOUT_MS") ||
          env_integer("ZAIK_LLM_TIMEOUT_MS") ||
          Keyword.get(app_config, :timeout_ms) ||
          Keyword.get(llm_config, :timeout_ms, 180_000),
      temperature:
        env_float("ZAIK_LLAMA_CPP_TEMPERATURE") ||
          env_float("ZAIK_LLM_TEMPERATURE") ||
          Keyword.get(app_config, :temperature) ||
          Keyword.get(llm_config, :temperature, 0.2)
    }
  end

  defp normalize_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} ->
        %{role: to_string(role), content: to_string(content)}

      %{"role" => role, "content" => content} ->
        %{role: to_string(role), content: to_string(content)}

      other ->
        other
    end)
  end

  defp maybe_put_response_format(payload, "json"),
    do: Map.put(payload, :response_format, %{type: "json_object"})

  defp maybe_put_response_format(payload, :json),
    do: Map.put(payload, :response_format, %{type: "json_object"})

  defp maybe_put_response_format(payload, _format), do: payload

  defp maybe_put_extra_body(payload, extra) when is_list(extra),
    do: Map.merge(payload, Map.new(extra))

  defp maybe_put_extra_body(payload, extra) when is_map(extra), do: Map.merge(payload, extra)
  defp maybe_put_extra_body(payload, _extra), do: payload

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

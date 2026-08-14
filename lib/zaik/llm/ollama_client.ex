defmodule Zaik.LLM.OllamaClient do
  @moduledoc """
  Minimal Ollama chat client for local LLM workloads.
  """

  @default_url "http://localhost:11434"
  @default_model "qwen3-coder:30b"
  @default_num_ctx 32_768
  @default_num_predict 512
  @default_keep_alive "30m"

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
  end

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
  end

  def config do
    app_config = Application.get_env(:zaik, :llm, [])

    %{
      provider: Keyword.get(app_config, :provider, :ollama),
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
    ensure_http_started()
    url = config().ollama_url |> String.trim_trailing("/") |> Kernel.<>(path)
    body = Jason.encode!(payload)
    headers = [{~c"content-type", ~c"application/json"}]

    case :httpc.request(
           :post,
           {to_charlist(url), headers, ~c"application/json", body},
           [timeout: timeout],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        decode_response(status, response_body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_response(status, body) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, {:invalid_json, body}}
    end
  end

  defp decode_response(status, body) do
    decoded =
      case Jason.decode(body) do
        {:ok, value} -> value
        {:error, _} -> body
      end

    {:error, {:http_error, status, decoded}}
  end

  defp ensure_http_started do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
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

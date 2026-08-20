defmodule Zaik.LLM do
  @moduledoc """
  Provider-neutral LLM facade for Zaik.

  Runtime code should call this module instead of a provider-specific client.
  The configured provider can be Ollama, llama.cpp/llama-server, or another
  module implementing `Zaik.LLM.Provider`.
  """

  @default_provider :ollama
  @default_model "qwen3-coder:30b"
  @default_num_ctx 32_768
  @default_num_predict 512
  @default_keep_alive "30m"

  def config do
    app_config = Application.get_env(:zaik, :llm, [])

    %{
      provider:
        env_provider("ZAIK_LLM_PROVIDER", Keyword.get(app_config, :provider, @default_provider)),
      client: configured_client(app_config),
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

  def client, do: config().client

  def chat(prompt, opts \\ []) when is_binary(prompt), do: client().chat(prompt, opts)
  def generate(prompt, opts \\ []) when is_binary(prompt), do: client().generate(prompt, opts)

  def provider_client(:ollama), do: Zaik.LLM.OllamaClient
  def provider_client(:llama_cpp), do: Zaik.LLM.LlamaCppClient
  def provider_client(:llama_server), do: Zaik.LLM.LlamaCppClient
  def provider_client(:openai_compatible), do: Zaik.LLM.LlamaCppClient

  def provider_client(provider) when is_atom(provider) do
    case Code.ensure_loaded(provider) do
      {:module, module} -> module
      {:error, _} -> Zaik.LLM.OllamaClient
    end
  end

  def provider_client(provider) when is_binary(provider) do
    case provider |> String.trim() |> String.downcase() |> String.replace("-", "_") do
      "ollama" -> Zaik.LLM.OllamaClient
      "llama_cpp" -> Zaik.LLM.LlamaCppClient
      "llama.cpp" -> Zaik.LLM.LlamaCppClient
      "llama_server" -> Zaik.LLM.LlamaCppClient
      "llama-server" -> Zaik.LLM.LlamaCppClient
      "openai_compatible" -> Zaik.LLM.LlamaCppClient
      "openai-compatible" -> Zaik.LLM.LlamaCppClient
      module_name -> module_client(module_name)
    end
  end

  def provider_client(_provider), do: Zaik.LLM.OllamaClient

  defp configured_client(app_config) do
    case System.get_env("ZAIK_LLM_CLIENT") || Keyword.get(app_config, :client) do
      nil ->
        provider_client(
          env_provider("ZAIK_LLM_PROVIDER", Keyword.get(app_config, :provider, @default_provider))
        )

      client when is_atom(client) ->
        client

      client when is_binary(client) ->
        provider_client(client)
    end
  end

  defp module_client(module_name) do
    module = Module.concat([module_name])

    case Code.ensure_loaded(module) do
      {:module, loaded} -> loaded
      {:error, _} -> Zaik.LLM.OllamaClient
    end
  rescue
    _ -> Zaik.LLM.OllamaClient
  end

  defp env_provider(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.trim(value)
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

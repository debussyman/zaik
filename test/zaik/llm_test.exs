defmodule Zaik.LLMTest do
  use ExUnit.Case, async: false

  setup do
    original_llm = Application.get_env(:zaik, :llm)
    original_llama_cpp = Application.get_env(:zaik, :llama_cpp)

    on_exit(fn ->
      restore_env("ZAIK_LLM_PROVIDER")
      restore_env("ZAIK_LLM_CLIENT")
      restore_env("ZAIK_LLAMA_CPP_URL")
      restore_env("ZAIK_LLAMA_CPP_MODEL")
      restore_env("ZAIK_LLM_MODEL")
      Application.put_env(:zaik, :llm, original_llm)
      Application.put_env(:zaik, :llama_cpp, original_llama_cpp)
    end)

    :ok
  end

  defmodule TransientModelLoadHTTP do
    def post_json(_base_url, _path, payload, _timeout) do
      attempt = Process.get(:model_load_attempt, 0) + 1
      Process.put(:model_load_attempt, attempt)
      send(self(), {:model_load_attempt, attempt})

      if attempt == 1 do
        {:error,
         {:http_error, 500,
          %{"error" => %{"message" => "model name=#{payload.model} failed to load"}}}}
      else
        {:ok,
         %{
           "model" => payload.model,
           "choices" => [%{"message" => %{"content" => "OK"}}]
         }}
      end
    end
  end

  defmodule FakeHTTP do
    def post_json(base_url, path, payload, timeout) do
      send(self(), {:llama_cpp_request, base_url, path, payload, timeout})

      {:ok,
       %{
         "model" => Map.get(payload, :model),
         "choices" => [
           %{"message" => %{"content" => "{\"type\":\"final\",\"answer\":\"ok\"}"}}
         ]
       }}
    end
  end

  test "provider facade selects ollama by default" do
    System.delete_env("ZAIK_LLM_PROVIDER")
    Application.put_env(:zaik, :llm, provider: :ollama)

    assert Zaik.LLM.client() == Zaik.LLM.OllamaClient
  end

  test "provider facade selects llama.cpp from env" do
    System.put_env("ZAIK_LLM_PROVIDER", "llama.cpp")

    assert Zaik.LLM.client() == Zaik.LLM.LlamaCppClient
  end

  test "llama.cpp client retries a transient managed-model load failure" do
    Process.delete(:model_load_attempt)

    assert {:ok, %{response: "OK"}} =
             Zaik.LLM.LlamaCppClient.chat("hello",
               model: "house",
               http_client: TransientModelLoadHTTP,
               model_load_retry_delay_ms: 0
             )

    assert_received {:model_load_attempt, 1}
    assert_received {:model_load_attempt, 2}
  end

  test "llama.cpp client uses OpenAI-compatible chat completions" do
    System.put_env("ZAIK_LLAMA_CPP_URL", "http://localhost:18080")
    System.put_env("ZAIK_LLAMA_CPP_MODEL", "qwen3.8:27b")

    assert {:ok, result} =
             Zaik.LLM.LlamaCppClient.chat("hello",
               http_client: FakeHTTP,
               format: "json",
               num_predict: 64,
               temperature: 0.0,
               think: false,
               timeout_ms: 12_345
             )

    assert result.model == "qwen3.8:27b"
    assert result.response == "{\"type\":\"final\",\"answer\":\"ok\"}"

    assert_received {:llama_cpp_request, "http://localhost:18080", "/v1/chat/completions",
                     payload, 12_345}

    assert payload.model == "qwen3.8:27b"
    assert payload.messages == [%{role: "user", content: "hello"}]
    assert payload.stream == false
    assert payload.max_tokens == 64
    assert payload.temperature == 0.0
    assert payload.response_format == %{type: "json_object"}
    assert payload.chat_template_kwargs == %{enable_thinking: false}
  end

  defp restore_env(name) do
    System.delete_env(name)
  end
end

defmodule Zaik.LLM.Provider do
  @moduledoc """
  Behaviour for chat/generation model providers used by Zaik.

  Providers normalize their responses to a common map shape:

      %{
        model: binary() | nil,
        response: binary(),
        done: boolean() | nil,
        raw: map()
      }

  This keeps the rest of Zaik independent from Ollama, llama.cpp, or any
  future OpenAI-compatible/local inference server.
  """

  @type result :: %{
          optional(:model) => String.t() | nil,
          required(:response) => String.t(),
          optional(:done) => boolean() | nil,
          optional(:raw) => map()
        }

  @callback chat(prompt :: String.t(), opts :: keyword()) :: {:ok, result()} | {:error, term()}
  @callback generate(prompt :: String.t(), opts :: keyword()) ::
              {:ok, result()} | {:error, term()}
  @callback config() :: map()
end

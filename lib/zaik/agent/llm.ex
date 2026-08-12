defmodule Zaik.Agent.LLM do
  @moduledoc """
  One-shot local LLM prompt task backed by Ollama.
  """

  use Zaik.Agent.TaskRunner

  @impl true
  def agent_init(task, _opts) do
    payload = payload_map(task.payload)

    {:ok,
     %{
       client: Map.get(payload, :client) || Map.get(payload, "client") || Zaik.LLM.OllamaClient,
       model:
         Map.get(payload, :model) || Map.get(payload, "model") ||
           Zaik.LLM.OllamaClient.config().default_model,
       num_predict:
         Map.get(payload, :num_predict) || Map.get(payload, "num_predict") ||
           Zaik.LLM.OllamaClient.config().num_predict,
       num_ctx:
         Map.get(payload, :num_ctx) || Map.get(payload, "num_ctx") ||
           Zaik.LLM.OllamaClient.config().num_ctx,
       temperature:
         Map.get(payload, :temperature) || Map.get(payload, "temperature") ||
           Zaik.LLM.OllamaClient.config().temperature
     }}
  end

  @impl true
  def run_task(task, state) do
    payload = payload_map(task.payload)

    case prompt_from_payload(payload) do
      {:ok, prompt} ->
        opts = [
          model: state.model,
          num_predict: state.num_predict,
          num_ctx: state.num_ctx,
          temperature: state.temperature
        ]

        case state.client.chat(prompt, opts) do
          {:ok, result} -> {:ok, result, state}
          {:error, reason} -> {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp payload_map(payload) when is_map(payload), do: payload
  defp payload_map(_payload), do: %{}

  defp prompt_from_payload(payload) do
    prompt = Map.get(payload, :prompt) || Map.get(payload, "prompt")

    cond do
      is_binary(prompt) and String.trim(prompt) != "" -> {:ok, String.trim(prompt)}
      true -> {:error, :missing_prompt}
    end
  end
end

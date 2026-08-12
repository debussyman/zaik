defmodule Zaik.Agent.LLMTest do
  use ExUnit.Case, async: true

  defmodule FakeOllamaClient do
    def chat(prompt, opts) do
      {:ok,
       %{
         model: Keyword.fetch!(opts, :model),
         response: "fake response to #{prompt}",
         done: true,
         raw: %{}
       }}
    end
  end

  test "runs prompt through configured client" do
    task =
      Zaik.Task.new(:llm_prompt, %{
        prompt: "hello",
        client: FakeOllamaClient,
        model: "fake-model",
        num_predict: 8,
        num_ctx: 128,
        temperature: 0.0
      })

    assert {:ok, state} = Zaik.Agent.LLM.agent_init(task, [])
    assert {:ok, result, _state} = Zaik.Agent.LLM.run_task(task, state)
    assert result.model == "fake-model"
    assert result.response == "fake response to hello"
  end

  test "fails when prompt is missing" do
    task = Zaik.Task.new(:llm_prompt, %{})

    assert {:ok, state} = Zaik.Agent.LLM.agent_init(task, [])
    assert {:error, :missing_prompt, _state} = Zaik.Agent.LLM.run_task(task, state)
  end
end

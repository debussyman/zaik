defmodule Mix.Tasks.Zaik.AgentEval do
  @moduledoc """
  Runs live Ollama evals for Zaik.AgentChat tool use.

      mix zaik.agent_eval
      mix zaik.agent_eval --model qwen3-coder:30b --timeout-ms 90000

  The evals use a canned SQL tool so results focus on whether the model emits
  valid JSON tool calls and grounded final answers.
  """

  use Mix.Task

  @shortdoc "Run live AgentChat tool-use evals"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [model: :string, timeout_ms: :integer],
        aliases: [m: :model]
      )

    summary = Zaik.AgentChat.Evals.run(opts)

    Enum.each(summary.results, fn result ->
      status = if result.passed?, do: "PASS", else: "FAIL"
      Mix.shell().info("#{status} #{result.name}")
      Mix.shell().info("  prompt: #{result.prompt}")
      Mix.shell().info("  response: #{inspect(result.response, limit: 2_000)}")

      Enum.each(result.tool_calls, fn call ->
        Mix.shell().info("  tool: db=#{inspect(Keyword.get(call.opts, :db))} query=#{call.query}")
      end)

      failed_checks = Enum.reject(result.checks, & &1.passed?)

      if failed_checks != [] do
        Mix.shell().info(
          "  failed checks: #{Enum.map_join(failed_checks, ", ", &to_string(&1.name))}"
        )
      end
    end)

    Mix.shell().info("Agent evals: #{summary.passed} passed, #{summary.failed} failed")

    if summary.failed > 0 do
      Mix.raise("Agent evals failed")
    end
  end
end

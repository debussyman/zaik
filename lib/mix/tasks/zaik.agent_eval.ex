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
        strict: [
          model: :string,
          timeout_ms: :integer,
          show_prompts: :boolean,
          include_optional: :boolean,
          include_home_control: :boolean
        ],
        aliases: [m: :model]
      )

    opts =
      if Keyword.get(opts, :include_home_control, false) do
        Keyword.put(opts, :include_optional, true)
      else
        opts
      end

    summary = Zaik.AgentChat.Evals.run(opts)

    Enum.each(summary.results, fn result ->
      status = if result.passed?, do: "PASS", else: "FAIL"
      Mix.shell().info("#{status} #{result.name}")
      Mix.shell().info("  prompt: #{result.prompt}")
      response_limit = if Keyword.get(opts, :show_prompts, false), do: :infinity, else: 2_000
      Mix.shell().info("  response: #{inspect(result.response, limit: response_limit)}")

      if Keyword.get(opts, :show_prompts, false) do
        Mix.shell().info("  planner prompt:\n#{result.planner_prompt}")
      end

      Enum.each(Map.get(result, :sql_calls, result.tool_calls), fn call ->
        Mix.shell().info(
          "  sql_tool: db=#{inspect(Keyword.get(call.opts, :db))} query=#{call.query}"
        )
      end)

      Enum.each(Map.get(result, :registered_calls, []), fn call ->
        Mix.shell().info("  registered_tool: #{call.tool} args=#{inspect(call.args, limit: 20)}")
      end)

      Enum.each(Map.get(result, :control_calls, []), fn call ->
        Mix.shell().info("  control_tool: #{call.tool} args=#{inspect(call.args, limit: 20)}")
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

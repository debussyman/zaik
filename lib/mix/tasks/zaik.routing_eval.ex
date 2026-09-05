defmodule Mix.Tasks.Zaik.RoutingEval do
  @moduledoc """
  Runs deterministic skill-aware routing/prompt/SQL-guard evals.

      mix zaik.routing_eval

  These evals do not call an LLM and do not publish MQTT. They catch regressions
  where skills hijack read questions or SQL plans let null device rows mask
  sensor data.
  """

  use Mix.Task

  @shortdoc "Run deterministic AgentChat routing/prompt evals"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    summary = Zaik.AgentChat.RoutingEvals.run()

    Enum.each(summary.results, fn result ->
      status = if result.passed?, do: "PASS", else: "FAIL"
      Mix.shell().info("#{status} #{result.name}")

      if result.prompt do
        Mix.shell().info("  prompt: #{result.prompt}")
      end

      failed_checks = Enum.reject(result.checks, & &1.passed?)

      if failed_checks != [] do
        Mix.shell().info(
          "  failed checks: #{Enum.map_join(failed_checks, ", ", &to_string(&1.name))}"
        )

        Mix.shell().info("  data: #{inspect(result.data, limit: 20, printable_limit: 500)}")
      end
    end)

    Mix.shell().info("Routing evals: #{summary.passed} passed, #{summary.failed} failed")

    if summary.failed > 0 do
      Mix.raise("Routing evals failed")
    end
  end
end

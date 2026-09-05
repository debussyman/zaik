defmodule Mix.Tasks.Zaik.MirrorEval do
  use Mix.Task

  @shortdoc "Run deterministic mirror-world home evals"

  @moduledoc """
  Runs end-to-end virtual-home scenarios through production tools, plans,
  capabilities, verification, and policy boundaries without publishing MQTT.

      mix zaik.mirror_eval
  """

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    summary = Zaik.Home.Mirror.Evals.run()

    Enum.each(summary.results, fn result ->
      status = if result.passed?, do: "PASS", else: "FAIL"
      Mix.shell().info("#{status} #{result.name}")
      Mix.shell().info("  result: #{inspect(result.result, limit: 20)}")

      if result.report do
        Mix.shell().info("  virtual side effects: #{result.report.side_effect_count}")
      end
    end)

    Mix.shell().info("Mirror evals: #{summary.passed} passed, #{summary.failed} failed")

    if summary.failed > 0, do: Mix.raise("Mirror evals failed")
  end
end

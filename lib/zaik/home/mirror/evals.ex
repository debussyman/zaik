defmodule Zaik.Home.Mirror.Evals do
  @moduledoc """
  Deterministic end-to-end regression scenarios for the virtual home.
  """

  alias Zaik.Home.Mirror.{Runner, Scenarios}

  def run do
    results = Enum.map(cases(), &run_case/1)

    %{
      passed: Enum.count(results, & &1.passed?),
      failed: Enum.count(results, &(not &1.passed?)),
      results: results
    }
  end

  def cases do
    [
      %{name: "bedtime_reaches_verified_desired_state", kind: :success},
      %{name: "invalid_plan_has_zero_side_effects", kind: :invalid},
      %{name: "later_executor_failure_reports_partial_completion", kind: :partial},
      %{name: "accepted_non_convergence_is_not_verified", kind: :stalled},
      %{name: "virtual_time_drives_expiry_and_retry_eligibility", kind: :virtual_retry}
    ]
  end

  defp run_case(%{kind: :success} = definition) do
    scenario = Scenarios.lily_bedtime_with_ac(id: definition.name)

    finish(definition, Runner.run(scenario, &execute_bedtime/2), fn run ->
      match?({:ok, %{verified: true}}, run.result) and run.report.passed? and
        run.report.side_effect_count == 2
    end)
  end

  defp run_case(%{kind: :invalid} = definition) do
    scenario = Scenarios.lily_bedtime_with_ac(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn _mirror, context ->
        execute_plan(
          context,
          [
            action("Lily's bedroom left blind", %{"position" => 101}),
            action("Lily's bedroom right blind", %{"position" => 71})
          ],
          "invalid"
        )
      end),
      fn run ->
        match?({:error, {:invalid_action_plan, _}}, run.result) and
          run.report.side_effect_count == 0
      end
    )
  end

  defp run_case(%{kind: :partial} = definition) do
    scenario =
      Scenarios.lily_bedtime_with_ac(
        id: definition.name,
        faults: %{"Lily's bedroom right blind" => :executor_failure}
      )

    finish(definition, Runner.run(scenario, &execute_bedtime/2), fn run ->
      match?({:error, {:action_plan_failed, %{status: "partially_completed"}}}, run.result) and
        run.report.side_effect_count == 1
    end)
  end

  defp run_case(%{kind: :stalled} = definition) do
    scenario =
      Scenarios.lily_bedtime_with_ac(
        id: definition.name,
        faults: %{"Lily's bedroom left blind" => :never_converges}
      )

    finish(
      definition,
      Runner.run(scenario, fn _mirror, context ->
        Zaik.Tools.Executor.run(
          "control_device",
          action("Lily's bedroom left blind", %{"state" => "CLOSE"}),
          request_context(context, definition.name)
        )
      end),
      fn run ->
        match?({:ok, %{status: "accepted", verified: false}}, run.result) and
          not run.report.passed? and run.report.side_effect_count == 1
      end
    )
  end

  defp run_case(%{kind: :virtual_retry} = definition) do
    scenario =
      Scenarios.lily_bedtime_with_ac(
        id: definition.name,
        faults: %{
          "Lily's bedroom left blind" => %{
            type: :delayed_convergence,
            delay_ms: 100,
            reported_position: 50
          }
        },
        metadata: %{verification_timeout_ms: 50, verification_wait_ms: 0}
      )

    finish(
      definition,
      Runner.run(scenario, fn mirror, context ->
        context = request_context(context, definition.name)

        with {:ok, action} <-
               Zaik.Tools.Executor.run(
                 "control_device",
                 action("Lily's bedroom left blind", %{"state" => "CLOSE"}),
                 context
               ),
             %{fired: 2} <- Zaik.Home.Mirror.advance(mirror, 100),
             {:ok, entry} <-
               Zaik.Home.ActionLedger.lookup(action.action_id, mirror.action_ledger),
             {:ok, decision} <-
               Zaik.Home.ActionRetryPolicy.evaluate(
                 entry,
                 context,
                 settle_ms: 0,
                 cooldown_ms: 0
               ) do
          {:ok, %{decision: decision, now: Zaik.Home.Mirror.now(mirror)}}
        end
      end),
      fn run ->
        match?(
          {:ok,
           %{
             decision: %{eligible: true, reason: "fresh_state_not_converged"},
             now: ~U[2026-01-01 00:00:00.100Z]
           }},
          run.result
        )
      end
    )
  end

  defp execute_bedtime(_mirror, context) do
    execute_plan(
      context,
      [
        action("Lily's bedroom left blind", %{"state" => "CLOSE"}),
        action("Lily's bedroom right blind", %{"preset" => "above AC"})
      ],
      "bedtime"
    )
  end

  defp execute_plan(context, actions, suffix) do
    Zaik.Tools.Executor.run(
      "execute_home_plan",
      %{"goal" => "Lily bedtime with AC", "actions" => actions},
      request_context(context, suffix)
    )
  end

  defp request_context(context, message_id) do
    Map.merge(context, %{channel: :mirror, chat_id: "mirror-eval", message_id: message_id})
  end

  defp action(device, target) do
    %{"device" => device, "capability" => "cover", "target" => target}
  end

  defp finish(definition, {:ok, run}, predicate) do
    %{
      name: definition.name,
      passed?: predicate.(run),
      result: run.result,
      report: run.report
    }
  end

  defp finish(definition, {:error, reason}, _predicate) do
    %{name: definition.name, passed?: false, result: {:error, reason}, report: nil}
  end
end

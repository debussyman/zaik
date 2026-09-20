defmodule Zaik.Home.CanaryTrialTest do
  use ExUnit.Case, async: false

  setup do
    now = ~U[2026-09-20 12:00:00Z]
    {:ok, clock_server} = start_supervised({Zaik.Home.Mirror.Clock, [now: now]})
    clock = {Zaik.Home.Mirror.Clock, clock_server}

    {:ok, decisions} =
      start_supervised(
        {Zaik.Home.Autonomy.DecisionStore,
         name: nil, db_path: ":memory:", max_rows: 100, clock: clock}
      )

    {:ok, rollouts} =
      start_supervised(
        {Zaik.Home.Autonomy.RolloutStore, name: nil, db_path: ":memory:", clock: clock}
      )

    {:ok, ledger} =
      start_supervised({Zaik.Home.ActionLedger, name: nil, db_path: ":memory:"})

    {:ok, telemetry} = start_supervised({Zaik.TelemetryWriteMonitor, name: nil, clock: clock})

    report = eligible_report()

    assert {:ok, rollout} =
             Zaik.Home.Autonomy.RolloutStore.approve(
               report,
               "operator",
               "single controlled trial",
               [clock: clock],
               rollouts
             )

    %{
      now: now,
      clock: clock,
      decisions: decisions,
      rollouts: rollouts,
      rollout: rollout,
      ledger: ledger,
      telemetry: telemetry
    }
  end

  test "proposal is inert and exact confirmation executes one explicit supervised action", ctx do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    evaluator = evaluator(ctx, counter, true)

    assert {:ok, proposal} =
             Zaik.Home.Autonomy.CanaryTrial.propose(
               ctx.rollout.id,
               %{entity_id: "blind-right", capability: "cover"},
               "operator",
               "verify the right blind preset physically",
               rollout_store: ctx.rollouts,
               evaluator: evaluator
             )

    assert proposal.type == "home_canary_trial"
    assert proposal.status == "pending"
    assert proposal.action["action"]["target"] == %{"position" => 71}
    assert Agent.get(counter, & &1) == 1

    test_pid = self()

    tool_executor = fn tool, args, context ->
      send(test_pid, {:canary_execution, tool, args, context})

      {:ok,
       %{
         action_id: "physical-trial-action",
         status: "accepted",
         verified: false,
         device: args["device"],
         capability: args["capability"],
         target: args["target"]
       }}
    end

    assert {:ok, confirmed} =
             Zaik.Home.Autonomy.CanaryTrial.confirm(
               proposal.id,
               "operator",
               rollout_store: ctx.rollouts,
               evaluator: evaluator,
               action_ledger: ctx.ledger,
               decision_store: ctx.decisions,
               telemetry_write_monitor: ctx.telemetry,
               tool_executor: tool_executor
             )

    assert confirmed.autonomy_execution_enabled == false
    assert confirmed.result.action_id == "physical-trial-action"

    assert_receive {:canary_execution, "control_device", args, execution_context}
    assert args["target"] == %{"position" => 71}
    refute Map.has_key?(execution_context, :autonomy_decision_id)
    assert execution_context.canary_rollout_id == ctx.rollout.id
    assert execution_context.operator_trial_causality.decision_id == "trial-decision-2"
    assert execution_context.operator_trial_causality.goal_id == "goal-2"

    assert {:ok, latest_decision} =
             Zaik.Home.Autonomy.DecisionStore.lookup("trial-decision-2", ctx.decisions)

    assert [outcome] = latest_decision.outcomes
    assert outcome["type"] == "operator_confirmed_canary_trial"
    assert outcome["rollout_id"] == ctx.rollout.id
    assert outcome["proposal_id"] == proposal.id
  end

  test "confirmation fails closed when the policy no longer proposes the exact action", ctx do
    {:ok, proposal_counter} = Agent.start_link(fn -> 0 end)
    proposal_evaluator = evaluator(ctx, proposal_counter, true)

    assert {:ok, proposal} =
             Zaik.Home.Autonomy.CanaryTrial.propose(
               ctx.rollout.id,
               %{entity_id: "blind-right", capability: "cover"},
               "operator",
               "must still be current",
               rollout_store: ctx.rollouts,
               evaluator: proposal_evaluator
             )

    refute_evaluator = evaluator(ctx, proposal_counter, false)

    assert {:error, :canary_action_no_longer_proposed} =
             Zaik.Home.Autonomy.CanaryTrial.confirm(
               proposal.id,
               "operator",
               rollout_store: ctx.rollouts,
               evaluator: refute_evaluator,
               action_ledger: ctx.ledger,
               decision_store: ctx.decisions,
               telemetry_write_monitor: ctx.telemetry,
               tool_executor: fn _, _, _ -> flunk("executor must not run") end
             )
  end

  defp evaluator(ctx, counter, proposed?) do
    fn scope ->
      index = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)
      decision = decision(index, scope, proposed?, ctx.now)
      assert {:ok, _} = Zaik.Home.Autonomy.DecisionStore.record(decision, ctx.decisions)
      {:ok, decision}
    end
  end

  defp decision(index, scope, proposed?, now) do
    action = %{
      entity_id: "blind-right",
      device: "Lily's bedroom right blind",
      capability: "cover",
      target: %{"position" => 71},
      candidate_id: "goal-#{index}",
      policy_id: "solar_heat_avoidance"
    }

    %{
      id: "trial-decision-#{index}",
      mode: :shadow,
      query: scope,
      snapshot_id: "trial-snapshot-#{index}",
      status: if(proposed?, do: "proposed", else: "satisfied"),
      context: %{},
      candidates: [],
      arbitration: %{},
      reconciliation: %{
        actions: if(proposed?, do: [action], else: []),
        blocked: [],
        satisfied: if(proposed?, do: [], else: [action])
      },
      policy_fingerprint: Zaik.Home.Policies.Registry.fingerprint(),
      created_at: DateTime.add(now, index, :second)
    }
  end

  defp eligible_report do
    descriptor =
      Zaik.Home.Policies.Registry.fetch("solar_heat_avoidance")
      |> elem(1)
      |> Map.fetch!(:descriptor)

    base = %{
      schema_version: 1,
      policy_id: descriptor.id,
      policy_version: descriptor.version,
      policy_descriptor_fingerprint: fingerprint(descriptor),
      policy_registry_fingerprint: Zaik.Home.Policies.Registry.fingerprint(),
      scope: "lily_bedroom",
      mirror_gate: %{eligible_for_shadow: true, safety_failures: 0},
      shadow_evidence: %{
        decision_count: 10,
        duration_seconds: 300_000,
        safety_failures: 0,
        capabilities: ["cover"]
      },
      requirements: %{
        minimum_shadow_seconds: 259_200,
        minimum_shadow_decisions: 10,
        allowed_policies: ["solar_heat_avoidance"],
        allowed_scopes: ["lily_bedroom"],
        allowed_capabilities: ["cover"],
        zero_safety_failures: true
      },
      blockers: [],
      eligible_for_operator_trial: true,
      execution_enabled: false
    }

    Map.put(base, :report_id, fingerprint(base))
  end

  defp fingerprint(value) do
    value
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value),
    do:
      value
      |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
      |> Enum.sort()

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end

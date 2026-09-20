defmodule Zaik.Home.AutonomyRolloutTest do
  use ExUnit.Case, async: true

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

    %{now: now, clock: clock, decisions: decisions, rollouts: rollouts}
  end

  test "requires repeated mirror success, sufficient shadow evidence, and exact allowlists",
       ctx do
    seed_shadow(ctx, 4, 3_600)

    assert {:ok, report} =
             Zaik.Home.Autonomy.RolloutGate.assess(
               "solar_heat_avoidance",
               "lily_bedroom",
               decision_store: ctx.decisions,
               eval_fun: fn -> true end,
               repeats: 3,
               minimum_pass_rate: 1.0,
               minimum_shadow_seconds: 3 * 3_600,
               minimum_shadow_decisions: 4,
               allowed_policies: ["solar_heat_avoidance"],
               allowed_scopes: ["lily_bedroom"],
               allowed_capabilities: ["cover"]
             )

    assert report.eligible_for_operator_trial
    assert report.execution_enabled == false
    assert report.blockers == []
    assert report.mirror_gate.passed == 3
    assert report.shadow_evidence.decision_count == 4
    assert report.shadow_evidence.duration_seconds == 3 * 3_600
    assert report.shadow_evidence.capabilities == ["cover"]
    assert :ok = Zaik.Home.Autonomy.RolloutGate.validate(report)
  end

  test "persists operator approval and supports immediate durable rollback", ctx do
    seed_shadow(ctx, 3, 3_600)

    assert {:ok, report} =
             Zaik.Home.Autonomy.RolloutGate.assess(
               "solar_heat_avoidance",
               "lily_bedroom",
               decision_store: ctx.decisions,
               eval_fun: fn -> %{failed: 0, results: []} end,
               repeats: 3,
               minimum_shadow_seconds: 2 * 3_600,
               minimum_shadow_decisions: 3,
               allowed_policies: ["solar_heat_avoidance"],
               allowed_scopes: ["lily_bedroom"],
               allowed_capabilities: ["cover"]
             )

    assert {:ok, approval} =
             Zaik.Home.Autonomy.RolloutStore.approve(
               report,
               "parent-operator",
               "controlled cover trial",
               [clock: ctx.clock],
               ctx.rollouts
             )

    assert approval.status == "approved"
    assert approval.execution_enabled == false
    assert approval.approved_by == "parent-operator"
    assert [active] = Zaik.Home.Autonomy.RolloutStore.active("lily_bedroom", ctx.rollouts)
    assert active.id == approval.id

    assert {:ok, rolled_back} =
             Zaik.Home.Autonomy.RolloutStore.rollback(
               approval.id,
               "parent-operator",
               "trial window closed",
               [clock: ctx.clock],
               ctx.rollouts
             )

    assert rolled_back.status == "rolled_back"
    assert rolled_back.rolled_back_by == "parent-operator"
    assert Zaik.Home.Autonomy.RolloutStore.active("lily_bedroom", ctx.rollouts) == []
  end

  test "fails closed with concise blockers and never enables execution", ctx do
    seed_shadow(ctx, 1, 0)

    assert {:ok, report} =
             Zaik.Home.Autonomy.RolloutGate.assess(
               "solar_heat_avoidance",
               "main_bedroom",
               decision_store: ctx.decisions,
               eval_fun: fn -> false end,
               repeats: 3,
               minimum_shadow_seconds: 10_000,
               minimum_shadow_decisions: 10,
               allowed_policies: ["daylight_harvesting"],
               allowed_scopes: ["lily_bedroom"],
               allowed_capabilities: ["switch"]
             )

    refute report.eligible_for_operator_trial
    refute report.execution_enabled
    assert "mirror_gate_failed" in report.blockers
    assert "minimum_shadow_duration_not_met" in report.blockers
    assert "minimum_shadow_decisions_not_met" in report.blockers
    assert "policy_not_allowlisted" in report.blockers
    assert "scope_not_allowlisted" in report.blockers
    assert "capability_not_allowlisted" in report.blockers

    assert {:error, {:rollout_not_eligible, _blockers}} =
             Zaik.Home.Autonomy.RolloutStore.approve(
               report,
               "operator",
               "must fail",
               [],
               ctx.rollouts
             )
  end

  defp seed_shadow(ctx, count, spacing_seconds) do
    for index <- 0..(count - 1) do
      created_at = DateTime.add(ctx.now, -(count - 1 - index) * spacing_seconds, :second)

      candidate = %{
        id: "goal-#{index}",
        policy_id: "solar_heat_avoidance",
        policy_version: "1",
        desired_state: [
          %{
            entity_id: "blind",
            device: "Lily blind",
            capability: "cover",
            target: %{"position" => 71}
          }
        ]
      }

      assert {:ok, _} =
               Zaik.Home.Autonomy.DecisionStore.record(
                 %{
                   id: "shadow-#{index}",
                   mode: :shadow,
                   query: "lily_bedroom",
                   snapshot_id: "snapshot-#{index}",
                   status: "proposed",
                   context: %{},
                   candidates: [candidate],
                   arbitration: %{},
                   reconciliation: %{actions: [], blocked: [], satisfied: []},
                   policy_fingerprint: Zaik.Home.Policies.Registry.fingerprint(),
                   created_at: created_at
                 },
                 ctx.decisions
               )
    end
  end
end

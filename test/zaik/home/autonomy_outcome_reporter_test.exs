defmodule Zaik.Home.AutonomyOutcomeReporterTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, decisions} =
      start_supervised(
        {Zaik.Home.Autonomy.DecisionStore, name: nil, db_path: ":memory:", max_rows: 20}
      )

    {:ok, telemetry} = start_supervised({Zaik.TelemetryWriteMonitor, name: nil})

    {:ok, ledger} =
      start_supervised(
        {Zaik.Home.ActionLedger,
         name: nil,
         db_path: ":memory:",
         decision_store: decisions,
         telemetry_write_monitor: telemetry}
      )

    decision = %{
      id: "decision-outcomes",
      mode: :shadow,
      query: "lily_bedroom",
      snapshot_id: "snapshot-outcomes",
      status: "proposed",
      context: %{},
      candidates: [
        %{
          id: "goal-daylight",
          policy_id: "daylight_harvesting",
          desired_state: []
        }
      ],
      arbitration: %{},
      reconciliation: %{},
      policy_fingerprint: "policy-fingerprint",
      created_at: "2026-01-01T00:00:00Z"
    }

    assert {:ok, _} = Zaik.Home.Autonomy.DecisionStore.record(decision, decisions)

    context = %{
      channel: "mirror",
      chat_id: "autonomy",
      message_id: "action-1",
      autonomy_decision_id: decision.id,
      autonomy_goal_id: "goal-daylight",
      autonomy_policy_id: "daylight_harvesting",
      autonomy_snapshot_id: decision.snapshot_id
    }

    %{decisions: decisions, telemetry: telemetry, ledger: ledger, context: context}
  end

  test "automatically records accepted and verified action outcomes with full causality", ctx do
    args = %{"device" => "blind", "target" => %{"position" => 0}}

    assert {:ok, key} =
             Zaik.Home.ActionLedger.claim("control_device", args, ctx.context, ctx.ledger)

    assert :ok =
             Zaik.Home.ActionLedger.complete(
               key,
               {:ok, %{action_id: "cover-action-1", status: "accepted", verified: false}},
               ctx.ledger
             )

    Zaik.Home.ActionLedger.mark_verification(
      key,
      "cover-action-1",
      %{
        status: "verified",
        verified: true,
        observed_at: "2026-01-01T00:00:02Z",
        observed: %{"position" => 0}
      },
      ctx.ledger
    )

    assert {:ok, _entry} = Zaik.Home.ActionLedger.lookup(key, ctx.ledger)

    assert {:ok, decision} =
             Zaik.Home.Autonomy.DecisionStore.lookup("decision-outcomes", ctx.decisions)

    assert Enum.map(decision.outcomes, & &1["status"]) == ["accepted", "verified"]

    for outcome <- decision.outcomes do
      assert outcome["decision_id"] == "decision-outcomes"
      assert outcome["goal_id"] == "goal-daylight"
      assert outcome["policy_id"] == "daylight_harvesting"
      assert outcome["snapshot_id"] == "snapshot-outcomes"
      assert outcome["ledger_key"] == key
      assert is_binary(outcome["event_id"])
    end

    assert Zaik.TelemetryWriteMonitor.status(ctx.telemetry).status == :ok
  end

  test "records failures, cancellation, timeout, and non-convergence idempotently", ctx do
    statuses = [
      {"failed", {:error, :adapter_unavailable}, nil},
      {"cancelled", {:ok, %{action_id: "cancelled", status: "accepted"}},
       %{status: "cancelled", reason: "operator_cancelled"}},
      {"timed_out", {:ok, %{action_id: "timed-out", status: "accepted"}},
       %{status: "expired", reason: "verification_timeout"}},
      {"non_converged", {:ok, %{action_id: "non-converged", status: "accepted"}},
       %{status: "expired", reason: "physical_non_convergence"}}
    ]

    Enum.with_index(statuses, 2)
    |> Enum.each(fn {{_expected, result, verification}, index} ->
      context = %{ctx.context | message_id: "action-#{index}"}
      args = %{"device" => "blind-#{index}", "target" => %{"position" => index}}

      assert {:ok, key} =
               Zaik.Home.ActionLedger.claim("control_device", args, context, ctx.ledger)

      assert :ok = Zaik.Home.ActionLedger.complete(key, result, ctx.ledger)

      if verification do
        action_id = result |> elem(1) |> Map.fetch!(:action_id)
        Zaik.Home.ActionLedger.mark_verification(key, action_id, verification, ctx.ledger)
        Zaik.Home.ActionLedger.mark_verification(key, action_id, verification, ctx.ledger)
        assert {:ok, _entry} = Zaik.Home.ActionLedger.lookup(key, ctx.ledger)
      end
    end)

    assert {:ok, decision} =
             Zaik.Home.Autonomy.DecisionStore.lookup("decision-outcomes", ctx.decisions)

    recorded = Enum.map(decision.outcomes, & &1["status"])
    assert "failed" in recorded
    assert "cancelled" in recorded
    assert "timed_out" in recorded
    assert "non_converged" in recorded
    assert Enum.count(recorded, &(&1 == "cancelled")) == 1
    assert Enum.count(recorded, &(&1 == "timed_out")) == 1
    assert Enum.count(recorded, &(&1 == "non_converged")) == 1
  end

  test "rejects incomplete or mismatched provenance before ledger claim", ctx do
    args = %{"device" => "blind", "target" => %{"position" => 0}}

    incomplete = Map.delete(ctx.context, :autonomy_goal_id)

    assert {:error, {:incomplete_autonomy_causality, :goal_id}} =
             Zaik.Home.ActionLedger.claim("control_device", args, incomplete, ctx.ledger)

    mismatched = %{ctx.context | autonomy_snapshot_id: "wrong-snapshot"}

    assert {:error, :autonomy_snapshot_mismatch} =
             Zaik.Home.ActionLedger.claim("control_device", args, mismatched, ctx.ledger)

    no_request_identity =
      Map.drop(ctx.context, [:channel, :chat_id, :message_id, :session_id, :update_id])

    assert {:error, :autonomy_request_identity_required} =
             Zaik.Home.ActionLedger.claim(
               "control_device",
               args,
               no_request_identity,
               ctx.ledger
             )

    {:ok, disabled_ledger} =
      start_supervised({Zaik.Home.ActionLedger, name: nil, enabled: false},
        id: :disabled_autonomy_ledger
      )

    assert {:error, :autonomy_causality_store_unavailable} =
             Zaik.Home.ActionLedger.claim(
               "control_device",
               args,
               ctx.context,
               disabled_ledger
             )
  end
end

defmodule Zaik.Home.AutonomyAlertsTest do
  use ExUnit.Case, async: true

  setup do
    now = ~U[2026-08-01 12:00:00Z]
    {:ok, clock_server} = start_supervised({Zaik.Home.Mirror.Clock, [now: now]})
    clock = {Zaik.Home.Mirror.Clock, clock_server}

    {:ok, decisions} =
      start_supervised(
        {Zaik.Home.Autonomy.DecisionStore,
         name: nil, db_path: ":memory:", max_rows: 100, clock: clock}
      )

    {:ok, telemetry} =
      start_supervised({Zaik.TelemetryWriteMonitor, name: nil, clock: clock})

    context = %{decision_store: decisions, telemetry_write_monitor: telemetry, clock: clock}
    %{now: now, clock: clock, decisions: decisions, telemetry: telemetry, context: context}
  end

  test "reports stale inputs, oscillation prevention, non-convergence, and telemetry failures",
       ctx do
    for index <- 1..3 do
      record_decision(ctx, index, [
        %{reason: "observation_stale", desired: %{scope: "lily_bedroom"}},
        %{reason: "policy_cooldown", desired: %{scope: "lily_bedroom"}}
      ])
    end

    assert {:ok, decision} =
             Zaik.Home.Autonomy.DecisionStore.lookup("decision-1", ctx.decisions)

    assert {:ok, _} =
             Zaik.Home.Autonomy.DecisionStore.record_outcome(
               decision.id,
               %{status: "non_converged", action_id: "action-1"},
               ctx.decisions
             )

    assert {:ok, _} =
             Zaik.Home.Autonomy.DecisionStore.record_outcome(
               decision.id,
               %{status: "non_converged", action_id: "action-2"},
               ctx.decisions
             )

    assert {:error, _} =
             Zaik.TelemetryWriteMonitor.report(
               :agent_chat_trace,
               {:error, :disk_full},
               %{trace_id: "bounded-id"},
               ctx.telemetry
             )

    assert {:ok, diagnostics} =
             Zaik.Home.Autonomy.Watchdog.evaluate(ctx.context,
               stale_threshold: 2,
               oscillation_threshold: 3,
               non_convergence_threshold: 2
             )

    assert diagnostics.status == "attention_required"

    assert MapSet.new(Enum.map(diagnostics.issues, & &1.type)) ==
             MapSet.new([
               "stale_critical_input",
               "oscillation_prevented",
               "repeated_non_convergence",
               "required_telemetry_write_failure"
             ])
  end

  test "delivers explicitly with durable cooldown and hashed destination", ctx do
    record_decision(ctx, 1, [
      %{reason: "observation_stale", desired: %{scope: "main_bedroom"}}
    ])

    test_pid = self()

    notifier = fn chat_id, text ->
      send(test_pid, {:autonomy_alert, chat_id, text})
      {:ok, %{message_id: 1}}
    end

    opts = [
      chat_id: "operator-chat",
      notifier: notifier,
      cooldown_seconds: 900,
      watchdog_opts: [stale_threshold: 1]
    ]

    assert {:ok, first} = Zaik.Home.Autonomy.Alerts.deliver(ctx.context, opts)
    assert first.sent == 1
    assert first.suppressed == 0

    assert_receive {:autonomy_alert, "operator-chat", text}
    assert text =~ "Zaik autonomy alert: stale_critical_input"
    assert text =~ "Scope: main_bedroom"

    assert {:ok, second} = Zaik.Home.Autonomy.Alerts.deliver(ctx.context, opts)
    assert second.sent == 0
    assert second.suppressed == 1
    refute_receive {:autonomy_alert, _, _}, 30
  end

  test "delivery cooldown survives decision-store restart", ctx do
    path =
      Path.join(
        System.tmp_dir!(),
        "zaik-autonomy-alerts-#{System.unique_integer([:positive])}.db"
      )

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> "-shm")
      File.rm(path <> "-wal")
    end)

    {:ok, first_store} =
      Zaik.Home.Autonomy.DecisionStore.start_link(
        name: nil,
        db_path: path,
        clock: ctx.clock
      )

    restart_context = %{ctx.context | decision_store: first_store}

    record_decision(%{ctx | decisions: first_store}, 1, [
      %{reason: "observation_stale", desired: %{scope: "office"}}
    ])

    opts = [
      chat_id: "operator",
      notifier: fn _, _ -> {:ok, :sent} end,
      cooldown_seconds: 900,
      watchdog_opts: [stale_threshold: 1]
    ]

    assert {:ok, %{sent: 1}} = Zaik.Home.Autonomy.Alerts.deliver(restart_context, opts)
    GenServer.stop(first_store)

    {:ok, recovered_store} =
      Zaik.Home.Autonomy.DecisionStore.start_link(
        name: nil,
        db_path: path,
        clock: ctx.clock
      )

    recovered_context = %{restart_context | decision_store: recovered_store}

    assert {:ok, %{sent: 0, suppressed: 1}} =
             Zaik.Home.Autonomy.Alerts.deliver(recovered_context, opts)

    GenServer.stop(recovered_store)
  end

  test "failed notifier releases its claim for immediate retry", ctx do
    assert {:error, _} =
             Zaik.TelemetryWriteMonitor.report(
               :autonomy_outcome,
               {:error, :write_failed},
               %{decision_id: "decision-x"},
               ctx.telemetry
             )

    base = [chat_id: "operator", cooldown_seconds: 900]

    assert {:ok, failed} =
             Zaik.Home.Autonomy.Alerts.deliver(
               ctx.context,
               Keyword.put(base, :notifier, fn _, _ -> {:error, :offline} end)
             )

    assert failed.errors == 1

    assert {:ok, retried} =
             Zaik.Home.Autonomy.Alerts.deliver(
               ctx.context,
               Keyword.put(base, :notifier, fn _, _ -> {:ok, :sent} end)
             )

    assert retried.sent == 1
    assert retried.suppressed == 0
  end

  defp record_decision(ctx, index, blocked) do
    decision = %{
      id: "decision-#{index}",
      mode: :shadow,
      query: "lily_bedroom",
      snapshot_id: "snapshot-#{index}",
      status: "blocked",
      context: %{},
      candidates: [],
      arbitration: %{},
      reconciliation: %{actions: [], satisfied: [], blocked: blocked},
      policy_fingerprint: "policy",
      created_at: DateTime.add(ctx.now, -index, :second)
    }

    assert {:ok, _} = Zaik.Home.Autonomy.DecisionStore.record(decision, ctx.decisions)
  end
end

defmodule Zaik.Home.StagedPlanAlertMonitorTest do
  use ExUnit.Case, async: true

  defmodule InertCoverExecutor do
    @behaviour Zaik.Home.Executor
    def capability, do: "cover"
    def prepare(_entity, target, _context), do: {:ok, target}
    def execute(_entity, _target, _context), do: {:error, :unexpected_execution}
  end

  test "periodic delivery is supervised and durably cooldown protected" do
    now = ~U[2026-08-01 12:00:00Z]
    {:ok, clock} = start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: now})
    {:ok, devices} = start_supervised({Zaik.Home.DeviceStore, name: nil})
    {:ok, tasks} = start_supervised({Task.Supervisor, name: nil})

    {:ok, store} =
      start_supervised(
        {Zaik.Home.StagedPlanStore,
         name: nil, db_path: ":memory:", clock: {Zaik.Home.Mirror.Clock, clock}, event_bus: false}
      )

    Zaik.Home.DeviceStore.upsert_device(
      devices,
      "Room blind",
      %{"position" => 0},
      %{"entity_id" => "room-blind", "area_id" => "room", "observed_at" => now}
    )

    context = %{
      staged_plan_store: store,
      device_store: devices,
      clock: {Zaik.Home.Mirror.Clock, clock},
      executor_opts: [modules: [InertCoverExecutor]]
    }

    {:ok, plan} =
      Zaik.Home.StagedPlan.preflight(
        "monitor unhealthy coordination",
        [
          %{
            id: "close-cover",
            actions: [%{device: "Room blind", capability: "cover", target: %{position: 100}}]
          }
        ],
        context,
        deadline_seconds: 120
      )

    assert {:ok, _} = Zaik.Home.StagedPlanStore.persist(plan, %{}, [], store)
    assert {:ok, _} = Zaik.Home.StagedPlanStore.claim_run(plan.id, "stuck-runner", [], store)
    Zaik.Home.Mirror.Clock.advance(clock, 10_000)

    test_pid = self()

    notifier = fn chat_id, text ->
      send(test_pid, {:monitor_alert, chat_id, text})
      {:ok, %{delivered: true}}
    end

    {:ok, monitor} =
      start_supervised(
        {Zaik.Home.StagedPlanAlertMonitor,
         name: nil,
         chat_id: "operator-chat",
         interval_seconds: 3_600,
         cooldown_seconds: 900,
         task_timeout_ms: 1_000,
         task_supervisor: tasks,
         notifier: notifier,
         context: context,
         watchdog_opts: [running_timeout_seconds: 5],
         clock: {Zaik.Home.Mirror.Clock, clock}}
      )

    assert :ok = Zaik.Home.StagedPlanAlertMonitor.barrier(monitor)
    assert_receive {:monitor_alert, "operator-chat", text}
    assert text =~ "evaluation_stuck"

    assert %{runs: 1, failures: 0, timeouts: 0, running: false} =
             Zaik.Home.StagedPlanAlertMonitor.status(monitor)

    assert :ok = Zaik.Home.StagedPlanAlertMonitor.run_now(monitor)
    assert :ok = Zaik.Home.StagedPlanAlertMonitor.barrier(monitor)
    refute_receive {:monitor_alert, _, _}, 50

    assert %{runs: 2, failures: 0, last_result: {:ok, %{sent: 0, suppressed: 1}}} =
             Zaik.Home.StagedPlanAlertMonitor.status(monitor)
  end
end

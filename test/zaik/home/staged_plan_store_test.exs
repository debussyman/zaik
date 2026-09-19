defmodule Zaik.Home.StagedPlanStoreTest do
  use ExUnit.Case, async: true

  defmodule InertCoverExecutor do
    @behaviour Zaik.Home.Executor
    def capability, do: "cover"
    def prepare(_entity, target, _context), do: {:ok, target}

    def execute(_entity, _target, context) do
      send(context.test_pid, :unexpected_staged_execution)
      {:ok, %{status: "accepted"}}
    end
  end

  setup do
    now = ~U[2026-07-15 14:00:00Z]
    {:ok, clock} = start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: now})
    {:ok, bus} = start_supervised({Zaik.Home.EventBus, name: nil})
    {:ok, devices} = start_supervised({Zaik.Home.DeviceStore, name: nil})

    Zaik.Home.DeviceStore.upsert_device(
      devices,
      "Room blind",
      %{"position" => 0},
      %{"ieee_address" => "blind", "area_id" => "room", "observed_at" => now}
    )

    {:ok, store} =
      start_supervised(
        {Zaik.Home.StagedPlanStore,
         name: nil, db_path: ":memory:", clock: {Zaik.Home.Mirror.Clock, clock}, event_bus: bus}
      )

    context = %{
      device_store: devices,
      clock: {Zaik.Home.Mirror.Clock, clock},
      executor_opts: [modules: [InertCoverExecutor]],
      test_pid: self()
    }

    %{now: now, clock: clock, bus: bus, devices: devices, store: store, context: context}
  end

  test "persists a preflighted plan idempotently without execution", context do
    plan = plan!(context, deadline_seconds: 300)

    assert {:ok, stored} =
             Zaik.Home.StagedPlanStore.persist(
               plan,
               %{owner: "parent", source: "operator", reason: "review first"},
               [],
               context.store
             )

    assert stored.status == "prepared"
    assert stored.owner == "parent"
    assert stored.plan["id"] == plan.id
    assert [%{id: id}] = Zaik.Home.StagedPlanStore.active([], context.store)
    assert id == plan.id

    assert {:ok, %{duplicate: true, id: ^id}} =
             Zaik.Home.StagedPlanStore.persist(plan, %{}, [], context.store)

    refute_received :unexpected_staged_execution
  end

  test "cancellation requires an exact ID and retains its operator audit", context do
    :ok = Zaik.Home.EventBus.subscribe(context.bus, self())
    plan = plan!(context)
    assert {:ok, _} = Zaik.Home.StagedPlanStore.persist(plan, %{}, [], context.store)

    assert_receive {:zaik_home_event,
                    %{type: :staged_plan_changed, plan_id: plan_id, status: "prepared"}}

    assert plan_id == plan.id

    assert {:ok, cancelled} =
             Zaik.Home.StagedPlanStore.cancel(
               plan.id,
               "parent",
               "changed my mind",
               [],
               context.store
             )

    assert cancelled.status == "cancelled"
    assert cancelled.cancelled_by == "parent"
    assert cancelled.cancellation_reason == "changed my mind"
    assert Zaik.Home.StagedPlanStore.active([], context.store) == []

    assert {:error, {:staged_plan_not_cancellable, "cancelled"}} =
             Zaik.Home.StagedPlanStore.cancel(plan.id, "parent", "again", [], context.store)

    assert {:error, :not_found} =
             Zaik.Home.StagedPlanStore.cancel("invented", "parent", "unknown", [], context.store)

    refute_received :unexpected_staged_execution
  end

  test "virtual time expires prepared plans conservatively", context do
    plan = plan!(context, deadline_seconds: 30)
    assert {:ok, _} = Zaik.Home.StagedPlanStore.persist(plan, %{}, [], context.store)

    Zaik.Home.Mirror.Clock.advance(context.clock, 29_999)
    assert [%{status: "prepared"}] = Zaik.Home.StagedPlanStore.active([], context.store)

    Zaik.Home.Mirror.Clock.advance(context.clock, 1)
    assert Zaik.Home.StagedPlanStore.active([], context.store) == []
    assert {:ok, expired} = Zaik.Home.StagedPlanStore.lookup(plan.id, [], context.store)
    assert expired.status == "expired"
    assert is_binary(expired.expired_at)

    assert {:error, {:staged_plan_not_cancellable, "expired"}} =
             Zaik.Home.StagedPlanStore.cancel(plan.id, "parent", "late", [], context.store)
  end

  test "runner ownership, checkpoints, and completion are durable", context do
    plan = plan!(context)
    assert {:ok, _} = Zaik.Home.StagedPlanStore.persist(plan, %{}, [], context.store)

    assert {:ok, running} =
             Zaik.Home.StagedPlanStore.claim_run(plan.id, "mirror-runner", [], context.store)

    assert running.status == "running"
    assert running.current_stage == 0

    assert {:error, :staged_plan_already_running} =
             Zaik.Home.StagedPlanStore.claim_run(plan.id, "other-runner", [], context.store)

    assert {:ok, checkpointed} =
             Zaik.Home.StagedPlanStore.checkpoint(
               plan.id,
               "mirror-runner",
               1,
               %{stage_id: "close-cover", status: "verified"},
               :running,
               [clock: context.context.clock],
               context.store
             )

    assert checkpointed.current_stage == 1

    assert [%{"stage_id" => "close-cover", "status" => "verified"}] =
             Enum.map(checkpointed.stage_results, &Map.drop(&1, ["recorded_at"]))

    assert {:ok, completed} =
             Zaik.Home.StagedPlanStore.finish(
               plan.id,
               "mirror-runner",
               %{status: "completed"},
               [clock: context.context.clock],
               context.store
             )

    assert completed.status == "completed"
    assert completed.final_result["status"] == "completed"
    assert is_binary(completed.completed_at)
    assert Zaik.Home.StagedPlanStore.active([], context.store) == []
  end

  test "waiting plans enforce durable poll cadence across claims", context do
    plan = plan!(context)
    assert {:ok, _} = Zaik.Home.StagedPlanStore.persist(plan, %{}, [], context.store)
    assert {:ok, _} = Zaik.Home.StagedPlanStore.claim_run(plan.id, "runner", [], context.store)

    assert {:ok, waiting} =
             Zaik.Home.StagedPlanStore.checkpoint(
               plan.id,
               "runner",
               0,
               %{stage_id: "close-cover", wait: %{timeout_seconds: 30, poll_interval_seconds: 2}},
               :waiting,
               [clock: context.context.clock],
               context.store
             )

    assert waiting.status == "waiting"
    assert is_binary(waiting.waiting_since)
    assert is_binary(waiting.next_evaluation_at)

    assert {:error,
            {:staged_plan_wait_not_ready, %{next_evaluation_at: next_at, retry_after_seconds: 2}}} =
             Zaik.Home.StagedPlanStore.claim_run(plan.id, "runner", [], context.store)

    assert next_at == waiting.next_evaluation_at
    now = Zaik.Home.Mirror.Clock.now(context.clock)

    assert {:error, :staged_plan_observation_before_wait} =
             Zaik.Home.StagedPlanStore.wake_waiting(
               plan.id,
               DateTime.add(now, -1, :second),
               [clock: context.context.clock],
               context.store
             )

    assert {:ok, awakened} =
             Zaik.Home.StagedPlanStore.wake_waiting(
               plan.id,
               now,
               [clock: context.context.clock],
               context.store
             )

    assert awakened.observation_wakeup_count == 1
    assert awakened.observation_wakeup_at == DateTime.to_iso8601(now)
    assert awakened.next_evaluation_at == DateTime.to_iso8601(now)

    assert {:ok, %{status: "running"}} =
             Zaik.Home.StagedPlanStore.claim_run(plan.id, "runner", [], context.store)
  end

  test "run diagnostics are typed, durable, and ordered newest first", context do
    plan = plan!(context)
    assert {:ok, _} = Zaik.Home.StagedPlanStore.persist(plan, %{}, [], context.store)

    assert {:ok, %{event_type: "scheduled"}} =
             Zaik.Home.StagedPlanStore.record_run_event(
               plan.id,
               :scheduled,
               %{source: "test"},
               [clock: context.context.clock],
               context.store
             )

    assert {:ok, %{event_type: "evaluation_started"}} =
             Zaik.Home.StagedPlanStore.record_run_event(
               plan.id,
               :evaluation_started,
               %{attempt: 1},
               [clock: context.context.clock],
               context.store
             )

    assert [started, scheduled] =
             Zaik.Home.StagedPlanStore.run_events(plan.id, 10, context.store)

    assert started.event_type == "evaluation_started"
    assert started.details == %{"attempt" => 1}
    assert scheduled.event_type == "scheduled"
    assert scheduled.details == %{"source" => "test"}

    assert {:error, {:invalid_staged_plan_run_event, "invented"}} =
             Zaik.Home.StagedPlanStore.record_run_event(
               plan.id,
               :invented,
               %{},
               [],
               context.store
             )
  end

  test "watchdog reports missed wakeups, stuck evaluations, and repeated failures", context do
    running_plan = plan!(context)
    waiting_plan = plan_with_goal!(context, "waiting diagnostic plan")

    assert {:ok, _} = Zaik.Home.StagedPlanStore.persist(running_plan, %{}, [], context.store)
    assert {:ok, _} = Zaik.Home.StagedPlanStore.persist(waiting_plan, %{}, [], context.store)

    assert {:ok, _} =
             Zaik.Home.StagedPlanStore.claim_run(running_plan.id, "runner", [], context.store)

    for attempt <- 1..3 do
      assert {:ok, _} =
               Zaik.Home.StagedPlanStore.record_run_event(
                 running_plan.id,
                 :evaluation_started,
                 %{attempt: attempt},
                 [clock: context.context.clock],
                 context.store
               )

      assert {:ok, _} =
               Zaik.Home.StagedPlanStore.record_run_event(
                 running_plan.id,
                 :timed_out,
                 %{attempt: attempt},
                 [clock: context.context.clock],
                 context.store
               )
    end

    assert {:ok, _} =
             Zaik.Home.StagedPlanStore.claim_run(waiting_plan.id, "waiter", [], context.store)

    assert {:ok, _} =
             Zaik.Home.StagedPlanStore.checkpoint(
               waiting_plan.id,
               "waiter",
               0,
               %{stage_id: "close-cover", wait: %{timeout_seconds: 30, poll_interval_seconds: 2}},
               :waiting,
               [clock: context.context.clock],
               context.store
             )

    Zaik.Home.Mirror.Clock.advance(context.clock, 10_000)

    assert {:ok, diagnostics} =
             Zaik.Home.StagedPlanWatchdog.evaluate(
               Map.put(context.context, :staged_plan_store, context.store),
               running_timeout_seconds: 5,
               missed_wakeup_grace_seconds: 1,
               consecutive_failure_threshold: 3
             )

    assert diagnostics.status == "attention_required"
    assert diagnostics.issue_count == 3

    assert MapSet.new(Enum.map(diagnostics.issues, & &1.type)) ==
             MapSet.new(["evaluation_stuck", "repeated_run_failure", "missed_wakeup"])
  end

  test "prepared and cancelled lifecycle survives store restart", context do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "zaik-staged-plans-#{System.unique_integer([:positive, :monotonic])}.db"
      )

    on_exit(fn -> Enum.each(Path.wildcard(db_path <> "*"), &File.rm/1) end)

    {:ok, first} =
      start_supervised(
        {Zaik.Home.StagedPlanStore,
         name: nil,
         db_path: db_path,
         clock: {Zaik.Home.Mirror.Clock, context.clock},
         event_bus: false},
        id: :first_staged_store
      )

    plan = plan!(context)
    assert {:ok, _} = Zaik.Home.StagedPlanStore.persist(plan, %{}, [], first)
    :ok = stop_supervised(:first_staged_store)

    {:ok, restarted} =
      start_supervised(
        {Zaik.Home.StagedPlanStore,
         name: nil,
         db_path: db_path,
         clock: {Zaik.Home.Mirror.Clock, context.clock},
         event_bus: false},
        id: :restarted_staged_store
      )

    assert {:ok, %{id: id, status: "prepared"}} =
             Zaik.Home.StagedPlanStore.lookup(plan.id, [], restarted)

    assert id == plan.id
  end

  defp plan!(context, opts \\ []), do: plan_with_goal!(context, "stored staged plan", opts)

  defp plan_with_goal!(context, goal, opts \\ []) do
    {:ok, plan} =
      Zaik.Home.StagedPlan.preflight(
        goal,
        [
          %{
            id: "close-cover",
            actions: [
              %{device: "Room blind", capability: "cover", target: %{position: 100}}
            ]
          }
        ],
        context.context,
        opts
      )

    plan
  end
end

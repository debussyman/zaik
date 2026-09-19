defmodule Zaik.Home.StagedPlanTest do
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
    {:ok, devices} = start_supervised({Zaik.Home.DeviceStore, name: nil})

    Zaik.Home.DeviceStore.upsert_device(
      devices,
      "Room sensor",
      %{"temperature" => 25.0, "illuminance" => 42, "presence" => true},
      %{"ieee_address" => "sensor", "area_id" => "room", "observed_at" => now}
    )

    for {name, id} <- [{"Left blind", "left"}, {"Right blind", "right"}] do
      Zaik.Home.DeviceStore.upsert_device(
        devices,
        name,
        %{"position" => 0, "state" => "OPEN"},
        %{"ieee_address" => id, "area_id" => "room", "observed_at" => now}
      )
    end

    %{
      now: now,
      clock: clock,
      context: %{
        device_store: devices,
        clock: {Zaik.Home.Mirror.Clock, clock},
        executor_opts: [modules: [InertCoverExecutor]],
        test_pid: self()
      }
    }
  end

  test "preflights and evaluates a typed canonical capability condition", context do
    input = %{
      "device" => "Room sensor",
      "capability" => "temperature",
      "field" => "fahrenheit",
      "operator" => "gte",
      "value" => 76,
      "max_age_seconds" => 60
    }

    assert {:ok, condition} =
             Zaik.Home.ActionPlan.Condition.preflight(input, context.context)

    assert {:ok, evaluation} =
             Zaik.Home.ActionPlan.Condition.evaluate(condition, context.context)

    assert evaluation.matched == true
    assert evaluation.observed == 77.0
    assert evaluation.expected == 76
    assert evaluation.entity_id == "sensor"
  end

  test "fails closed on stale evidence and rejects arbitrary fields and predicates", context do
    assert {:error, {:unknown_capability_state_field, "sql"}} =
             Zaik.Home.ActionPlan.Condition.preflight(
               %{
                 device: "Room sensor",
                 capability: "temperature",
                 field: "sql",
                 operator: "eq",
                 value: "SELECT 1"
               },
               context.context
             )

    assert {:error, {:unsupported_condition_operator, "eval"}} =
             Zaik.Home.ActionPlan.Condition.preflight(
               %{
                 device: "Room sensor",
                 capability: "temperature",
                 field: "fahrenheit",
                 operator: "eval",
                 value: 76
               },
               context.context
             )

    assert {:ok, condition} =
             Zaik.Home.ActionPlan.Condition.preflight(
               %{
                 device: "Room sensor",
                 capability: "illuminance",
                 field: "value",
                 operator: "lte",
                 value: 50,
                 max_age_seconds: 30
               },
               context.context
             )

    Zaik.Home.Mirror.Clock.advance(context.clock, 31_000)

    assert {:error, {:stale_condition_observation, %{age_seconds: 31}}} =
             Zaik.Home.ActionPlan.Condition.evaluate(condition, context.context)
  end

  test "fully preflights all stages without executing or waiting", context do
    stages = [
      %{
        id: "open-cover",
        conditions: [],
        actions: [
          %{device: "Left blind", capability: "cover", target: %{state: "OPEN"}}
        ]
      },
      %{
        id: "close-if-hot",
        conditions: [
          %{
            device: "Room sensor",
            capability: "temperature",
            field: "fahrenheit",
            operator: "gte",
            value: 76
          }
        ],
        condition_mode: "all",
        wait: %{timeout_seconds: 30, poll_interval_seconds: 2},
        on_condition_false: "cancel_plan",
        actions: [
          %{device: "Right blind", capability: "cover", target: %{position: 71}}
        ]
      }
    ]

    assert {:ok, plan} =
             Zaik.Home.StagedPlan.preflight(
               "manage solar heat",
               stages,
               context.context,
               deadline_seconds: 300
             )

    assert plan.status == "prepared"
    assert length(plan.stages) == 2
    assert DateTime.diff(plan.expires_at, plan.prepared_at, :second) == 300
    assert Enum.map(plan.stages, & &1.id) == ["open-cover", "close-if-hot"]
    assert hd(Enum.at(plan.stages, 1).conditions).operator == "gte"
    refute_received :unexpected_staged_execution
  end

  test "one invalid later stage rejects the complete plan before side effects", context do
    stages = [
      %{
        id: "valid",
        actions: [%{device: "Left blind", capability: "cover", target: %{position: 100}}]
      },
      %{
        id: "invalid",
        actions: [%{device: "Right blind", capability: "cover", target: %{position: 101}}]
      }
    ]

    assert {:error, {:invalid_staged_plan, [%{stage_id: "invalid"}]}} =
             Zaik.Home.StagedPlan.preflight("invalid staged plan", stages, context.context)

    refute_received :unexpected_staged_execution
  end

  test "waits require typed conditions and unsafe branch behavior is rejected", context do
    assert {:error, {:invalid_staged_plan, errors}} =
             Zaik.Home.StagedPlan.preflight(
               "unsafe branch",
               [
                 %{
                   id: "branch",
                   conditions: [],
                   wait: %{timeout_seconds: 30},
                   on_condition_false: "run_anyway",
                   actions: [
                     %{device: "Left blind", capability: "cover", target: %{position: 100}}
                   ]
                 }
               ],
               context.context
             )

    assert [%{reason: {:unsupported_condition_false_behavior, "run_anyway"}}] = errors
  end
end

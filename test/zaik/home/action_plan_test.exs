defmodule Zaik.Home.ActionPlanTest do
  use ExUnit.Case, async: true

  defmodule FakeCoverExecutor do
    @behaviour Zaik.Home.Executor

    def capability, do: "cover"

    def prepare(entity, target, context) do
      send(context.test_pid, {:prepared, entity.id, target})
      {:ok, target}
    end

    def execute(entity, %{"position" => 99}, context) do
      send(context.test_pid, {:executed, entity.id, %{"position" => 99}})
      {:error, :motor_jammed}
    end

    def execute(entity, target, context) do
      send(context.test_pid, {:executed, entity.id, target})
      {:ok, %{entity_id: entity.id, target: target, status: "accepted", verified: false}}
    end
  end

  defmodule VerifyingCoverExecutor do
    @behaviour Zaik.Home.Executor

    def capability, do: "cover"

    def execute(entity, target, context) do
      action_id = context.action_id
      verifier = context.action_verifier

      {:ok, _} =
        Zaik.Home.ActionVerifier.register(
          action_id,
          entity.name,
          "cover",
          target,
          server: verifier
        )

      {:ok, _} = Zaik.Home.ActionVerifier.published(action_id, server: verifier)
      Zaik.Home.ActionVerifier.observe(entity.name, target, DateTime.utc_now(), server: verifier)

      {:ok,
       %{
         action_id: action_id,
         entity_id: entity.id,
         target: target,
         status: "accepted",
         verified: false
       }}
    end
  end

  setup do
    {:ok, store} = start_supervised({Zaik.Home.DeviceStore, name: nil})

    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Left blind",
      %{"position" => 100, "state" => "OPEN"},
      %{"ieee_address" => "left", "area_id" => "bedroom"}
    )

    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Right blind",
      %{"position" => 100, "state" => "OPEN"},
      %{"ieee_address" => "right", "area_id" => "bedroom"}
    )

    context = %{
      device_store: store,
      executor_opts: [modules: [FakeCoverExecutor]],
      test_pid: self()
    }

    %{store: store, context: context}
  end

  test "preflights every action before executing the first side effect", %{context: context} do
    actions = [
      %{"device" => "Left blind", "capability" => "cover", "target" => %{"state" => "CLOSE"}},
      %{"device" => "Right blind", "capability" => "cover", "target" => %{"position" => 71}}
    ]

    assert {:ok, result} = Zaik.Home.ActionPlan.run("bedtime", actions, context)
    assert result.status == "accepted"
    assert result.completed_count == 2
    assert result.action_count == 2
    assert result.verified == false

    assert_receive {:prepared, "left", %{"position" => 0}}
    assert_receive {:prepared, "right", %{"position" => 71}}
    assert_receive {:executed, "left", %{"position" => 0}}
    assert_receive {:executed, "right", %{"position" => 71}}
  end

  test "uses unique child action IDs and aggregates correlated verification", %{store: store} do
    {:ok, verifier} =
      start_supervised({Zaik.Home.ActionVerifier, name: nil, timeout_ms: 500, wait_ms: 100})

    context = %{
      action_id: "ingress-action",
      action_verifier: verifier,
      device_store: store,
      verification_wait_ms: 100,
      executor_opts: [modules: [VerifyingCoverExecutor]]
    }

    actions = [
      %{"device" => "Left blind", "capability" => "cover", "target" => %{"position" => 0}},
      %{"device" => "Right blind", "capability" => "cover", "target" => %{"position" => 71}}
    ]

    assert {:ok, result} = Zaik.Home.ActionPlan.run("verified bedtime", actions, context)
    assert result.status == "verified"
    assert result.verified == true
    assert length(result.verification_ids) == 2
    assert Enum.uniq(result.verification_ids) == result.verification_ids
    assert Enum.all?(result.actions, & &1.result.verified)
  end

  test "one invalid action prevents all execution", %{context: context} do
    actions = [
      %{"device" => "Left blind", "capability" => "cover", "target" => %{"state" => "CLOSE"}},
      %{"device" => "Right blind", "capability" => "cover", "target" => %{"position" => 101}}
    ]

    assert {:error, {:invalid_action_plan, errors}} =
             Zaik.Home.ActionPlan.run("invalid setup", actions, context)

    assert Enum.any?(errors, &(&1.index == 1 and &1.reason == :invalid_cover_target))
    assert_receive {:prepared, "left", %{"position" => 0}}
    refute_received {:executed, _entity, _target}
  end

  test "reports partial completion without hiding the completed action", %{context: context} do
    actions = [
      %{"device" => "Left blind", "capability" => "cover", "target" => %{"position" => 0}},
      %{"device" => "Right blind", "capability" => "cover", "target" => %{"position" => 99}}
    ]

    assert {:error, {:action_plan_failed, report}} =
             Zaik.Home.ActionPlan.run("partial setup", actions, context)

    assert report.status == "partially_completed"
    assert report.completed_count == 1
    assert report.action_count == 2
    assert hd(report.completed).action.entity_id == "left"
    assert report.failed.action.entity_id == "right"
    assert report.failed.reason =~ "motor_jammed"
    assert report.remaining == []
  end

  test "resolves presets to concrete targets during preflight", %{store: store} do
    {:ok, preset_store} =
      start_supervised({Zaik.Home.DevicePresetStore, name: nil, db_path: ":memory:"})

    assert {:ok, _preset} =
             Zaik.Home.DevicePresetStore.put(
               "Right blind",
               "above vent",
               "cover",
               %{"position" => 71},
               %{},
               preset_store
             )

    context = %{device_store: store, preset_store: preset_store}

    assert {:ok, plan} =
             Zaik.Home.ActionPlan.preflight(
               "presets",
               [
                 %{
                   "device" => "Right blind",
                   "capability" => "cover",
                   "target" => %{"preset" => "above vent"}
                 }
               ],
               context
             )

    assert [action] = plan.actions
    assert action.requested_target == %{"preset" => "above vent"}
    assert action.target == %{"position" => 71}
  end

  test "plan tool normalizes safe action and preset aliases", %{context: context} do
    assert {:ok, result} =
             Zaik.Home.Tools.ExecutePlan.run(
               %{
                 "plan" => [
                   %{"device" => "left_blind", "action" => "close", "target" => "fully"},
                   %{
                     "device" => "right_blind",
                     "action" => "set_preset",
                     "preset" => "above vent"
                   }
                 ]
               },
               context
             )

    assert result.completed_count == 2
    assert_receive {:executed, "left", %{"position" => 0}}
    assert_receive {:executed, "right", %{"preset" => "above vent"}}
  end

  test "plan tool recognizes target-as-device aliases without bypassing resolution", %{
    context: context
  } do
    assert {:ok, result} =
             Zaik.Home.Tools.ExecutePlan.run(
               %{
                 "actions" => [
                   %{
                     "action" => "close",
                     "position" => 0,
                     "target" => "left_blind"
                   },
                   %{
                     "action" => "set_preset",
                     "preset" => "above vent",
                     "target" => "right_blind"
                   }
                 ]
               },
               context
             )

    assert result.completed_count == 2
    assert_receive {:executed, "left", %{"position" => 0}}
    assert_receive {:executed, "right", %{"preset" => "above vent"}}
  end

  test "plan tool does not treat a skill name as an executable plan", %{context: context} do
    assert {:error, {:invalid_action_plan, [%{reason: :actions_must_be_a_list}]}} =
             Zaik.Home.Tools.ExecutePlan.run(%{"plan" => "bedtime_skill"}, context)

    refute_received {:executed, _entity, _target}
  end

  test "rejects duplicate semantic actions", %{context: context} do
    action = %{
      "device" => "Left blind",
      "capability" => "cover",
      "target" => %{"position" => 0}
    }

    assert {:error, {:invalid_action_plan, errors}} =
             Zaik.Home.ActionPlan.preflight("duplicate", [action, action], context)

    assert Enum.any?(errors, &(&1.reason == :duplicate_action))
    refute_received {:executed, _entity, _target}
  end
end

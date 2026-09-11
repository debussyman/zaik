defmodule Zaik.Home.AutonomyEngineTest do
  use ExUnit.Case, async: false

  setup do
    now = ~U[2026-07-15 14:00:00Z]
    {:ok, clock} = start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: now})
    {:ok, devices} = start_supervised({Zaik.Home.DeviceStore, name: nil})
    {:ok, history} = start_supervised({Zaik.Home.HistoryStore, name: nil, db_path: ":memory:"})

    {:ok, decisions} =
      start_supervised({Zaik.Home.Autonomy.DecisionStore, name: nil, db_path: ":memory:"})

    {:ok, overrides} =
      start_supervised({Zaik.Home.Autonomy.ManualOverrideStore, name: nil, db_path: ":memory:"})

    {:ok, engine} =
      start_supervised(
        {Zaik.Home.Autonomy.Engine,
         name: nil,
         enabled: true,
         mode: :shadow,
         occupancy_tracker: false,
         manual_override_store: overrides}
      )

    sensor_metadata = %{
      "ieee_address" => "sensor",
      "area_id" => "lily_bedroom",
      "observed_at" => now,
      "source" => "test"
    }

    Zaik.Home.DeviceStore.upsert_device(
      devices,
      "Lily's room sensor",
      %{"temperature" => 22.22, "illuminance" => 15, "presence" => true},
      sensor_metadata
    )

    :ok =
      Zaik.Home.HistoryStore.record_device(
        history,
        "Lily's room sensor",
        %{"temperature" => 22.22, "illuminance" => 15, "presence" => true},
        sensor_metadata,
        observed_at: DateTime.add(now, -300, :second)
      )

    for {name, id} <- [
          {"Lily's bedroom left blind", "left"},
          {"Lily's bedroom right blind", "right"}
        ] do
      Zaik.Home.DeviceStore.upsert_device(
        devices,
        name,
        %{"position" => 100},
        %{
          "ieee_address" => id,
          "area_id" => "lily_bedroom",
          "observed_at" => now,
          "source" => "test"
        }
      )
    end

    %{
      now: now,
      clock: clock,
      devices: devices,
      history: history,
      decisions: decisions,
      overrides: overrides,
      engine: engine
    }
  end

  test "shadow evaluation records candidates and unresolved actions without executing", context do
    assert {:ok, decision} =
             Zaik.Home.Autonomy.Engine.evaluate(
               "lily",
               [
                 clock: {Zaik.Home.Mirror.Clock, context.clock},
                 device_store: context.devices,
                 history_store: context.history,
                 decision_store: context.decisions,
                 environment_config: %{
                   utc_offset_minutes: 0,
                   day_start_hour: 6,
                   night_start_hour: 20
                 },
                 policy_opts: [maximum_temperature_f: 76.0]
               ],
               context.engine
             )

    assert decision.mode == :shadow
    assert decision.status == "proposed"
    assert length(decision.candidates) == 1
    assert length(decision.reconciliation.actions) == 2
    assert decision.reconciliation.satisfied == []

    assert {:ok, stored} =
             Zaik.Home.Autonomy.DecisionStore.lookup(decision.id, context.decisions)

    assert stored.mode == "shadow"
    assert stored.snapshot_id == decision.snapshot_id
    assert length(stored.candidates) == 1
    assert length(stored.reconciliation["actions"]) == 2
  end

  test "accepted relevant events are coalesced through virtual debounce", context do
    {:ok, bus} = start_supervised({Zaik.Home.EventBus, name: nil}, id: :autonomy_event_bus)

    {:ok, event_engine} =
      start_supervised(
        {Zaik.Home.Autonomy.Engine,
         name: nil,
         enabled: true,
         mode: :shadow,
         subscribe_events: true,
         event_bus: bus,
         event_debounce_ms: 100,
         clock: {Zaik.Home.Mirror.Clock, context.clock},
         device_store: context.devices,
         occupancy_tracker: false,
         history_store: context.history,
         decision_store: context.decisions,
         environment_config: %{utc_offset_minutes: 0},
         policy_opts: [maximum_temperature_f: 76.0]},
        id: :event_autonomy_engine
      )

    event = %{
      type: :device_observed,
      device: "Lily's bedroom left blind",
      changed_keys: ["position"],
      observed_at: context.now
    }

    Zaik.Home.EventBus.publish(event, bus)
    Zaik.Home.EventBus.publish(%{event | device: "Lily's bedroom right blind"}, bus)

    assert_eventually(fn -> Zaik.Home.Autonomy.Engine.status(event_engine).pending_count == 1 end)
    Zaik.Home.Mirror.Clock.advance(context.clock, 99)
    assert Zaik.Home.Autonomy.Engine.status(event_engine).last_decision == nil
    Zaik.Home.Mirror.Clock.advance(context.clock, 1)

    assert_eventually(fn ->
      case Zaik.Home.Autonomy.Engine.status(event_engine).last_decision do
        %{status: "proposed", reconciliation: %{actions: actions}} -> length(actions) == 2
        _ -> false
      end
    end)

    assert length(Zaik.Home.Autonomy.DecisionStore.recent(20, context.decisions)) == 1

    Zaik.Home.EventBus.publish(event, bus)
    assert_eventually(fn -> Zaik.Home.Autonomy.Engine.status(event_engine).pending_count == 1 end)
    Zaik.Home.Mirror.Clock.advance(context.clock, 59_999)
    assert length(Zaik.Home.Autonomy.DecisionStore.recent(20, context.decisions)) == 1
    Zaik.Home.Mirror.Clock.advance(context.clock, 1)

    assert_eventually(fn ->
      length(Zaik.Home.Autonomy.DecisionStore.recent(20, context.decisions)) == 2
    end)
  end

  test "active manual override is included in evidence and suppresses background policy",
       context do
    clock = {Zaik.Home.Mirror.Clock, context.clock}

    assert {:ok, lease} =
             Zaik.Home.Autonomy.ManualOverrideStore.create(
               "lily_bedroom",
               %{owner: "parent", reason: "keep blinds closed", ttl_seconds: 600},
               [clock: clock],
               context.overrides
             )

    assert {:ok, decision} =
             Zaik.Home.Autonomy.Engine.evaluate(
               "lily",
               [
                 clock: clock,
                 device_store: context.devices,
                 history_store: context.history,
                 decision_store: context.decisions,
                 manual_override_store: context.overrides,
                 environment_config: %{utc_offset_minutes: 0}
               ],
               context.engine
             )

    assert decision.status == "no_candidates"
    assert decision.candidates == []
    assert [%{id: id, owner: "parent"}] = decision.context.manual_overrides
    assert id == lease.id
  end

  test "active execution is impossible in the shadow-only engine", context do
    assert {:error, {:execution_mode_not_enabled, :active}} =
             Zaik.Home.Autonomy.Engine.evaluate(
               "lily",
               [mode: :active],
               context.engine
             )

    assert Zaik.Home.Autonomy.DecisionStore.recent(20, context.decisions) == []
  end

  test "nighttime shadow evaluation records no candidate", context do
    assert {:ok, decision} =
             Zaik.Home.Autonomy.Engine.evaluate(
               "lily",
               [
                 clock: {Zaik.Home.Mirror.Clock, context.clock},
                 device_store: context.devices,
                 history_store: context.history,
                 decision_store: context.decisions,
                 environment_config: %{
                   utc_offset_minutes: 10 * 60,
                   day_start_hour: 6,
                   night_start_hour: 20
                 }
               ],
               context.engine
             )

    assert decision.status == "no_candidates"
    assert decision.candidates == []
    assert decision.reconciliation.actions == []
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(2)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end

defmodule Zaik.Home.AutonomyEngineTest do
  use ExUnit.Case, async: false

  setup do
    now = ~U[2026-07-15 14:00:00Z]
    {:ok, clock} = start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: now})
    {:ok, devices} = start_supervised({Zaik.Home.DeviceStore, name: nil})
    {:ok, history} = start_supervised({Zaik.Home.HistoryStore, name: nil, db_path: ":memory:"})

    {:ok, decisions} =
      start_supervised({Zaik.Home.Autonomy.DecisionStore, name: nil, db_path: ":memory:"})

    {:ok, engine} =
      start_supervised({Zaik.Home.Autonomy.Engine, name: nil, enabled: true, mode: :shadow})

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
end

defmodule Zaik.Home.RoomContextTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, device_store} = start_supervised({Zaik.Home.DeviceStore, name: nil})

    {:ok, history_store} =
      start_supervised({Zaik.Home.HistoryStore, name: nil, db_path: ":memory:"})

    {:ok, clock} =
      start_supervised(
        {Zaik.Home.Mirror.Clock, name: nil, now: ~U[2026-08-14 12:00:00Z]},
        id: :room_context_clock
      )

    metadata = %{
      "ieee_address" => "sensor-1",
      "area_id" => "lily_bedroom",
      "source" => "test"
    }

    Zaik.Home.DeviceStore.upsert_device(
      device_store,
      "Lily's room sensor",
      %{"temperature" => 24.8889, "humidity" => 52, "illuminance" => 18, "presence" => true},
      metadata
    )

    for {observed_at, temperature} <- [
          {~U[2026-08-14 11:00:00Z], 24.0},
          {~U[2026-08-14 11:45:00Z], 24.8889}
        ] do
      :ok =
        Zaik.Home.HistoryStore.record_device(
          history_store,
          "Lily's room sensor",
          %{
            "temperature" => temperature,
            "humidity" => 52,
            "illuminance" => 18,
            "presence" => true
          },
          metadata,
          observed_at: observed_at
        )
    end

    for {name, id, position} <- [
          {"Lily's bedroom left blind", "left", 100},
          {"Lily's bedroom right blind", "right", 71}
        ] do
      Zaik.Home.DeviceStore.upsert_device(
        device_store,
        name,
        %{"position" => position},
        %{"ieee_address" => id, "area_id" => "lily_bedroom", "source" => "test"}
      )
    end

    %{device_store: device_store, history_store: history_store, clock: clock}
  end

  test "builds reproducible current, historical, occupancy, and environment context", context do
    opts = [
      device_store: context.device_store,
      history_store: context.history_store,
      occupancy_tracker: false,
      desired_state_store: false,
      clock: {Zaik.Home.Mirror.Clock, context.clock},
      window_minutes: 180,
      environment_config: %{
        utc_offset_minutes: -240,
        hemisphere: "north",
        day_start_hour: 6,
        night_start_hour: 20
      }
    ]

    assert {:ok, first} = Zaik.Home.RoomContext.build("Lily's room", opts)
    assert {:ok, second} = Zaik.Home.RoomContext.build("Lily's room", opts)

    assert first.snapshot_id == second.snapshot_id
    assert first.areas == ["lily_bedroom"]
    assert first.occupancy.status == "occupied"
    assert first.environment.season == "summer"
    assert first.environment.solar_phase == "day"
    assert first.environment.local_time == "08:00:00"
    assert length(first.entities) == 3

    temperature = first.history["temperature_f"]
    assert temperature.status == "ok"
    assert temperature.sample_count == 2
    assert_in_delta temperature.average, 76.0, 0.01
    assert_in_delta temperature.delta, 1.6, 0.01
    assert temperature.trend == "rising"
    assert temperature.freshness_seconds == 900
  end

  test "falls back to entity lookup for legacy history without an area", context do
    {:ok, legacy_history} =
      start_supervised({Zaik.Home.HistoryStore, name: nil, db_path: ":memory:"},
        id: :legacy_room_context_history
      )

    :ok =
      Zaik.Home.HistoryStore.record_device(
        legacy_history,
        "Lily's room sensor",
        %{"temperature" => 24.0},
        %{"ieee_address" => "legacy-sensor"},
        observed_at: ~U[2026-08-14 11:30:00Z]
      )

    assert {:ok, result} =
             Zaik.Home.RoomContext.build("lily",
               device_store: context.device_store,
               history_store: legacy_history,
               occupancy_tracker: false,
               desired_state_store: false,
               clock: {Zaik.Home.Mirror.Clock, context.clock},
               history_capabilities: ["temperature_f"],
               environment_config: %{utc_offset_minutes: -240}
             )

    assert result.areas == ["lily_bedroom"]
    assert result.history["temperature_f"].sample_count == 1
  end

  test "registered area-context tool uses injected world bindings", context do
    assert {:ok, %{descriptor: %{name: "get_area_context"}}} =
             Zaik.Tools.Registry.fetch("room_context")

    assert {:ok, result} =
             Zaik.Home.Tools.GetAreaContext.run(
               %{
                 "query" => "Lily's room",
                 "window_minutes" => 180,
                 "history_capabilities" => ["temperature_f", "presence"]
               },
               %{
                 device_store: context.device_store,
                 history_store: context.history_store,
                 occupancy_tracker: false,
                 desired_state_store: false,
                 clock: {Zaik.Home.Mirror.Clock, context.clock},
                 environment_config: %{utc_offset_minutes: -240}
               }
             )

    assert result.history["temperature_f"].sample_count == 2
    assert result.history["presence"].latest == true
  end
end

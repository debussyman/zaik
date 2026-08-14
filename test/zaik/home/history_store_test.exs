defmodule Zaik.Home.HistoryStoreTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, history} = start_supervised({Zaik.Home.HistoryStore, name: nil, db_path: ":memory:"})
    %{history: history}
  end

  test "records devices and structured readings", %{history: history} do
    observed_at = ~U[2026-08-14 12:00:00Z]

    assert :ok =
             Zaik.Home.HistoryStore.record_device(
               history,
               "Lily's room multi-sensor",
               %{
                 "temperature" => 26.0,
                 "humidity" => 50.5,
                 "illuminance" => 120,
                 "presence" => true,
                 "battery" => 100
               },
               %{"ieee_address" => "0xabc", "topic" => "zigbee2mqtt/Lily"},
               observed_at: observed_at
             )

    assert Zaik.Home.HistoryStore.count_readings(history, "lily") == 1

    assert [%{friendly_name: "Lily's room multi-sensor", metadata: metadata}] =
             Zaik.Home.HistoryStore.list_devices(history)

    assert metadata["ieee_address"] == "0xabc"

    assert {:ok, [reading]} = Zaik.Home.HistoryStore.recent_readings(history, "lily", limit: 5)
    assert reading.temperature_c == 26.0
    assert reading.temperature_f == 78.8
    assert reading.humidity == 50.5
    assert reading.illuminance == 120.0
    assert reading.presence == true
    assert reading.payload["battery"] == 100
  end

  test "queries readings since a timestamp", %{history: history} do
    Zaik.Home.HistoryStore.record_device(history, "Lily", %{"temperature" => 25.0}, %{},
      observed_at: ~U[2026-08-14 10:00:00Z]
    )

    Zaik.Home.HistoryStore.record_device(history, "Lily", %{"temperature" => 24.0}, %{},
      observed_at: ~U[2026-08-14 11:00:00Z]
    )

    assert {:ok, [reading]} =
             Zaik.Home.HistoryStore.readings_since(history, "lily", ~U[2026-08-14 10:30:00Z])

    assert reading.temperature_c == 24.0
  end
end

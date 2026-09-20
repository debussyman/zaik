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

  test "persists explicit area aliases and serves bounded typed capability history", %{
    history: history
  } do
    assert :ok =
             Zaik.Home.HistoryStore.record_device(
               history,
               "Lily's room multi-sensor",
               %{"temperature" => 25.0},
               %{"ieee_address" => "0xlily"},
               observed_at: ~U[2026-08-14 10:00:00Z]
             )

    assert :ok =
             Zaik.Home.HistoryStore.record_device(
               history,
               "Lily's room multi-sensor",
               %{"temperature" => 26.0},
               %{"ieee_address" => "0xlily"},
               observed_at: ~U[2026-08-14 11:00:00Z]
             )

    assert {:ok, identity} =
             Zaik.Home.HistoryStore.configure_entity(
               "0xlily",
               "lily_bedroom",
               ["nursery", "Lily climate"],
               history
             )

    assert identity.area_id == "lily_bedroom"
    assert identity.aliases == ["nursery", "Lily climate"]

    assert [%{area_id: "lily_bedroom", aliases: aliases}] =
             Zaik.Home.HistoryStore.list_devices(history)

    assert aliases == ["Lily climate", "nursery"]

    assert {:ok, [reading]} =
             Zaik.Home.HistoryStore.capability_history(
               "nursery",
               "temperature_f",
               [from: ~U[2026-08-14 10:30:00Z], limit: 10],
               history
             )

    assert reading.device_id == "0xlily"
    assert reading.area_id == "lily_bedroom"
    assert reading.value.celsius == 26.0
    assert reading.value.fahrenheit == 78.8
    assert reading.provenance == "observed"

    variants = [
      "lily bedroom",
      "temperature lily bedroom",
      "temperature readings for lily bedroom over the last 2 hours",
      "what were the temperatures from lily bedroom sensors?"
    ]

    assert Enum.all?(variants, fn query ->
             {:ok, readings} =
               Zaik.Home.HistoryStore.capability_history(
                 query,
                 "temperature",
                 [limit: 10],
                 history
               )

             Enum.map(readings, & &1.device_id) == ["0xlily", "0xlily"]
           end)
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

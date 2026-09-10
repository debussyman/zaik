defmodule Zaik.Home.EventBusTest do
  use ExUnit.Case, async: true

  test "device store publishes accepted observations but not stale or duplicate reports" do
    {:ok, bus} = start_supervised({Zaik.Home.EventBus, name: nil})
    :ok = Zaik.Home.EventBus.subscribe(bus)
    {:ok, store} = start_supervised({Zaik.Home.DeviceStore, name: nil, event_bus: bus})

    now = ~U[2026-07-15 14:00:00Z]
    metadata = %{"observed_at" => now, "ieee_address" => "sensor"}

    assert {:ok, _device} =
             Zaik.Home.DeviceStore.upsert_device(
               store,
               "Room sensor",
               %{"presence" => true},
               metadata
             )

    assert_receive {:zaik_home_event,
                    %{
                      type: :device_observed,
                      device: "Room sensor",
                      changed_keys: ["presence"]
                    }}

    assert {:ignored, :duplicate} =
             Zaik.Home.DeviceStore.upsert_device(
               store,
               "Room sensor",
               %{"presence" => true},
               metadata
             )

    assert {:ignored, :stale} =
             Zaik.Home.DeviceStore.upsert_device(
               store,
               "Room sensor",
               %{"presence" => false},
               %{"observed_at" => DateTime.add(now, -1, :second)}
             )

    refute_receive {:zaik_home_event, _event}, 20
  end
end

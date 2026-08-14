defmodule Zaik.Home.DeviceStoreTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, store} = start_supervised({Zaik.Home.DeviceStore, name: nil})
    %{store: store}
  end

  test "upserts and merges latest device payload", %{store: store} do
    assert {:ok, _device} =
             Zaik.Home.DeviceStore.upsert_device(store, "Office FP300", %{"presence" => true}, %{
               "topic" => "zigbee2mqtt/Office FP300"
             })

    assert {:ok, device} =
             Zaik.Home.DeviceStore.upsert_device(store, "Office FP300", %{"temperature" => 24.5})

    assert device.payload["presence"] == true
    assert device.payload["temperature"] == 24.5
    assert device.topic == "zigbee2mqtt/Office FP300"
  end

  test "finds devices by case-insensitive substring", %{store: store} do
    Zaik.Home.DeviceStore.upsert_device(store, "Lily presence sensor", %{"presence" => false})

    assert {:ok, device} = Zaik.Home.DeviceStore.find_device(store, "lily")
    assert device.friendly_name == "Lily presence sensor"
  end

  test "lists presence devices", %{store: store} do
    Zaik.Home.DeviceStore.upsert_device(store, "Presence", %{"presence" => true})
    Zaik.Home.DeviceStore.upsert_device(store, "Temperature", %{"temperature" => 20})

    assert [%{friendly_name: "Presence"}] = Zaik.Home.DeviceStore.presence_devices(store)
  end
end

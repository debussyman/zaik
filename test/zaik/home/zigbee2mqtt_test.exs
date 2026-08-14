defmodule Zaik.Home.Zigbee2MQTTTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, store} = start_supervised({Zaik.Home.DeviceStore, name: nil})
    %{store: store}
  end

  test "stores device state payloads", %{store: store} do
    payload = Jason.encode!(%{"presence" => true, "temperature" => 26.32})

    assert {:ok, _device} =
             Zaik.Home.Zigbee2MQTT.handle_publish("zigbee2mqtt/Lily presence sensor", payload,
               device_store: store,
               history_store: nil
             )

    assert {:ok, device} = Zaik.Home.DeviceStore.get_device(store, "Lily presence sensor")
    assert device.payload["presence"] == true
    assert device.payload["temperature"] == 26.32
  end

  test "ignores non-device bridge topics before decoding", %{store: store} do
    assert :ignored =
             Zaik.Home.Zigbee2MQTT.handle_publish("zigbee2mqtt/bridge/definitions", "not-json",
               device_store: store,
               history_store: nil
             )

    assert Zaik.Home.DeviceStore.list_devices(store) == []
  end

  test "bootstraps latest state from Zigbee2MQTT data files", %{store: store} do
    data_dir = Path.join(System.tmp_dir!(), "zaik-z2m-#{System.unique_integer([:positive])}")
    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf!(data_dir) end)

    File.write!(
      Path.join(data_dir, "configuration.yaml"),
      """
      devices:
        '0x54ef4410016fe9d8':
          friendly_name: Lily presence sensor
      """
    )

    File.write!(
      Path.join(data_dir, "database.db"),
      Jason.encode!(%{
        "type" => "EndDevice",
        "ieeeAddr" => "0x54ef4410016fe9d8",
        "manufName" => "Aqara",
        "modelId" => "lumi.sensor_occupy.agl8"
      })
    )

    File.write!(
      Path.join(data_dir, "state.json"),
      Jason.encode!(%{"0x54ef4410016fe9d8" => %{"presence" => false, "illuminance" => 88}})
    )

    assert {:ok, 1} =
             Zaik.Home.Zigbee2MQTT.bootstrap_from_files(
               data_dir: data_dir,
               device_store: store,
               history_store: nil
             )

    assert {:ok, device} = Zaik.Home.DeviceStore.get_device(store, "Lily presence sensor")
    assert device.payload["presence"] == false
    assert device.payload["illuminance"] == 88
    assert device.metadata["manufacturer"] == "Aqara"
  end

  test "stores metadata from bridge devices", %{store: store} do
    devices = [
      %{"type" => "Coordinator", "friendly_name" => "Coordinator"},
      %{
        "type" => "EndDevice",
        "friendly_name" => "Lily presence sensor",
        "ieee_address" => "0x54ef4410016fe9d8",
        "model_id" => "lumi.sensor_occupy.agl8",
        "manufacturer" => "Aqara"
      }
    ]

    assert :ok =
             Zaik.Home.Zigbee2MQTT.handle_publish(
               "zigbee2mqtt/bridge/devices",
               Jason.encode!(devices),
               device_store: store,
               history_store: nil
             )

    assert {:ok, device} = Zaik.Home.DeviceStore.get_device(store, "Lily presence sensor")
    assert device.metadata["ieee_address"] == "0x54ef4410016fe9d8"
    assert device.metadata["manufacturer"] == "Aqara"
  end
end

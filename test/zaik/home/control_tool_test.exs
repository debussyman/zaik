defmodule Zaik.Home.ControlToolTestPublisher do
  def publish(topic, payload, _opts) do
    Agent.update(__MODULE__, &[{topic, payload} | &1])
    :ok
  end

  def published, do: Agent.get(__MODULE__, &Enum.reverse/1)
end

defmodule Zaik.Home.ControlToolTest do
  use ExUnit.Case, async: false

  setup do
    original = Application.get_env(:zaik, :blinds)
    {:ok, device_store} = start_supervised({Zaik.Home.DeviceStore, name: nil})

    {:ok, preset_store} =
      start_supervised({Zaik.Home.DevicePresetStore, name: nil, db_path: ":memory:"})

    {:ok, _publisher} = Agent.start_link(fn -> [] end, name: Zaik.Home.ControlToolTestPublisher)

    Application.put_env(:zaik, :blinds,
      base_topic: "zigbee2mqtt",
      device_store: device_store,
      preset_store: preset_store,
      mqtt_client: Zaik.Home.ControlToolTestPublisher
    )

    on_exit(fn -> Application.put_env(:zaik, :blinds, original || []) end)

    Zaik.Home.DeviceStore.upsert_device(device_store, "Lily's bedroom left blind", %{
      "position" => 100,
      "state" => "OPEN"
    })

    Zaik.Home.DeviceStore.upsert_device(device_store, "Lily's bedroom right blind", %{
      "position" => 71,
      "state" => "OPEN"
    })

    Zaik.Home.DevicePresetStore.put(
      "Lily's bedroom right blind",
      "above AC",
      "cover",
      %{"position" => 71},
      %{},
      preset_store
    )

    :ok
  end

  test "accepts top-level action/preset shapes from model tool calls" do
    assert {:ok, left} =
             Zaik.Home.ControlTool.run("control_blind", %{
               "device" => "lily_bedroom_left_blind",
               "action" => "close"
             })

    assert left.payload == %{"position" => 0}

    assert {:ok, right} =
             Zaik.Home.ControlTool.run("control_blind", %{
               "device" => "lily_bedroom_right_blind",
               "action" => "set_preset",
               "preset" => "above AC"
             })

    assert right.payload == %{"position" => 71}

    assert Zaik.Home.ControlToolTestPublisher.published() == [
             {"zigbee2mqtt/Lily's bedroom left blind/set", %{"position" => 0}},
             {"zigbee2mqtt/Lily's bedroom right blind/set", %{"position" => 71}}
           ]
  end
end

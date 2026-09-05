defmodule Zaik.Home.BlindsTestPublisher do
  def publish(topic, payload, _opts) do
    Agent.update(__MODULE__, &[{topic, payload} | &1])
    :ok
  end

  def published do
    Agent.get(__MODULE__, &Enum.reverse/1)
  end
end

defmodule Zaik.Home.BlindsTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, device_store} = start_supervised({Zaik.Home.DeviceStore, name: nil})

    db_path =
      Path.join(
        System.tmp_dir!(),
        "zaik-blinds-test-presets-#{System.unique_integer([:positive])}.db"
      )

    {:ok, preset_store} =
      start_supervised({Zaik.Home.DevicePresetStore, name: nil, db_path: db_path})

    {:ok, _publisher} = Agent.start_link(fn -> [] end, name: Zaik.Home.BlindsTestPublisher)
    on_exit(fn -> File.rm(db_path) end)

    Zaik.Home.DeviceStore.upsert_device(
      device_store,
      "Lily's bedroom left blind",
      %{"position" => 37, "state" => "OPEN", "linkquality" => 104},
      %{"manufacturer" => "Smartwings", "model_id" => "WM25/L-Z"}
    )

    Zaik.Home.DeviceStore.upsert_device(
      device_store,
      "Lily's bedroom right blind",
      %{"position" => 37, "state" => "OPEN", "linkquality" => 104},
      %{"manufacturer" => "Smartwings", "model_id" => "WM25/L-Z"}
    )

    opts = [
      device_store: device_store,
      preset_store: preset_store,
      mqtt_client: Zaik.Home.BlindsTestPublisher,
      base_topic: "zigbee2mqtt"
    ]

    %{opts: opts, preset_store: preset_store}
  end

  test "lists blinds and fuzzy matches side", %{opts: opts} do
    assert [left, right] = Zaik.Home.Blinds.list("lily", opts)
    assert left.friendly_name =~ "left"
    assert right.friendly_name =~ "right"

    assert {:ok, left} = Zaik.Home.Blinds.get("lily left", opts)
    assert left.friendly_name == "Lily's bedroom left blind"

    assert {:error, {:ambiguous, names}} = Zaik.Home.Blinds.get("lily", opts)
    assert names == ["Lily's bedroom left blind", "Lily's bedroom right blind"]
  end

  test "captures a named preset from current position", %{opts: opts, preset_store: preset_store} do
    assert {:ok, preset} =
             Zaik.Home.Blinds.capture(
               "lily left",
               "above air conditioner",
               %{sender_id: "u1"},
               opts
             )

    assert preset["device_name"] == "Lily's bedroom left blind"
    assert preset["capability"] == "cover"
    assert preset["target"] == %{"position" => 37}
    assert preset["created_by"] == "u1"

    assert {:ok, fetched} =
             Zaik.Home.DevicePresetStore.get(
               "Lily's bedroom left blind",
               "above air conditioner",
               [capability: "cover"],
               preset_store
             )

    assert fetched["target"] == %{"position" => 37}
  end

  test "publishes validated position, state, and preset controls", %{opts: opts} do
    assert {:ok, _result} = Zaik.Home.Blinds.control("lily left", {:position, 42}, opts)
    assert {:ok, _result} = Zaik.Home.Blinds.control("lily right", {:state, "STOP"}, opts)

    assert {:ok, _preset} =
             Zaik.Home.Blinds.capture("lily left", "above air conditioner", %{}, opts)

    assert {:ok, _result} =
             Zaik.Home.Blinds.control("lily left", {:preset, "above air conditioner"}, opts)

    assert Zaik.Home.BlindsTestPublisher.published() == [
             {"zigbee2mqtt/Lily's bedroom left blind/set", %{"position" => 42}},
             {"zigbee2mqtt/Lily's bedroom right blind/set", %{"state" => "STOP"}},
             {"zigbee2mqtt/Lily's bedroom left blind/set", %{"position" => 37}}
           ]
  end

  test "rejects invalid position", %{opts: opts} do
    assert {:error, :invalid_position} =
             Zaik.Home.Blinds.control("lily left", {:position, 101}, opts)
  end
end

defmodule Zaik.Home.WorldTest do
  use ExUnit.Case, async: true

  defmodule TestReadOnlyCapability do
    @behaviour Zaik.Home.Capability

    def descriptor do
      %{
        id: "test_read_only",
        description: "Test-only world contract capability.",
        state_schema: %{"value" => "number"},
        target_schema: nil
      }
    end

    def detected?(_device), do: false
    def state(_device), do: %{}
    def validate_target(_target), do: {:error, :read_only_capability}
  end

  setup do
    {:ok, store} = start_supervised({Zaik.Home.DeviceStore, name: nil})
    %{store: store}
  end

  test "world contract is versioned, deterministic, and runtime-discovered", %{store: store} do
    contract = Zaik.Home.WorldContract.public()

    assert contract.schema_version == 2
    assert contract.calibration_schema.schema_version == 1
    assert contract.calibration_schema.authority == "inert configuration; no execution authority"
    assert byte_size(contract.fingerprint) == 64
    assert contract.fingerprint == Zaik.Home.WorldContract.fingerprint()

    assert Enum.map(contract.capabilities, & &1.id) ==
             Enum.sort(Enum.map(contract.capabilities, & &1.id))

    expanded =
      Zaik.Home.WorldContract.fingerprint(
        capability_opts: [additional_modules: [TestReadOnlyCapability]]
      )

    refute expanded == contract.fingerprint

    snapshot = Zaik.Home.World.snapshot(nil, device_store: store)
    assert snapshot.world_schema_version == contract.schema_version
    assert snapshot.world_contract_fingerprint == contract.fingerprint
  end

  test "derives typed entity state from adapter payloads", %{store: store} do
    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Nursery sensor",
      %{"temperature" => 26.5, "humidity" => 51, "presence" => false},
      %{"ieee_address" => "0xsensor", "area_id" => "nursery", "source" => "test"}
    )

    assert {:ok, entity} =
             Zaik.Home.World.get("nursery", device_store: store, capability: "temperature")

    assert entity.id == "0xsensor"
    assert entity.area_id == "nursery"
    assert entity.capabilities == ["humidity", "presence", "temperature"]
    assert_in_delta entity.state["temperature"].fahrenheit, 79.7, 0.01
    assert entity.state["presence"].detected == false

    assert {:ok, %{count: 1, entities: [state]}} =
             Zaik.Home.Tools.GetState.run(
               %{"room" => "nursery", "capability" => "temperature"},
               %{device_store: store}
             )

    assert state.name == "Nursery sensor"
  end

  test "adding unrelated covers does not change a temperature snapshot", %{store: store} do
    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Lily's room multi-sensor",
      %{"temperature" => 26.68, "humidity" => 52},
      %{"ieee_address" => "0xsensor", "area_id" => "lily_bedroom"}
    )

    baseline =
      Zaik.Home.World.snapshot("lily",
        device_store: store,
        capability: "temperature"
      )

    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Lily's bedroom left blind",
      %{"position" => 0, "state" => "OPEN"},
      %{"ieee_address" => "0xleft", "area_id" => "lily_bedroom"}
    )

    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Lily's bedroom right blind",
      %{"position" => 71, "state" => "OPEN"},
      %{"ieee_address" => "0xright", "area_id" => "lily_bedroom"}
    )

    expanded =
      Zaik.Home.World.snapshot("lily",
        device_store: store,
        capability: "temperature"
      )

    assert baseline.count == 1
    assert expanded.count == 1
    assert baseline.entities == expanded.entities
    assert hd(expanded.entities).name == "Lily's room multi-sensor"

    assert {:ok, right_blind} =
             Zaik.Home.World.get("lily bedroom right blind",
               device_store: store,
               capability: "cover"
             )

    assert right_blind.name == "Lily's bedroom right blind"

    assert {:ok, %{count: 2, entities: covers}} =
             Zaik.Home.Tools.GetState.run(
               %{"query" => "position lily blinds", "capability" => "cover"},
               %{device_store: store}
             )

    assert Enum.map(covers, & &1.name) == [
             "Lily's bedroom left blind",
             "Lily's bedroom right blind"
           ]
  end

  test "persisted aliases and areas participate in canonical lookup", %{store: store} do
    {:ok, history} =
      start_supervised({Zaik.Home.HistoryStore, name: nil, db_path: ":memory:"},
        id: :identity_history
      )

    metadata = %{"ieee_address" => "0xclimate"}

    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Lily's room multi-sensor",
      %{"temperature" => 25.0},
      metadata
    )

    :ok =
      Zaik.Home.HistoryStore.record_device(
        history,
        "Lily's room multi-sensor",
        %{"temperature" => 25.0},
        metadata
      )

    {:ok, _identity} =
      Zaik.Home.HistoryStore.configure_entity(
        "0xclimate",
        "lily_bedroom",
        ["nursery climate"],
        history
      )

    assert {:ok, entity} =
             Zaik.Home.World.get("nursery climate",
               device_store: store,
               identity_store: history,
               capability: "temperature"
             )

    assert entity.area_id == "lily_bedroom"
    assert entity.aliases == ["nursery climate"]
  end

  test "bootstrap state remains distinguishable from a fresh observation", %{store: store} do
    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Recovered sensor",
      %{"temperature" => 20},
      %{"source" => "zigbee2mqtt_state_file", "bootstrap" => true}
    )

    assert {:ok, entity} = Zaik.Home.World.get("Recovered sensor", device_store: store)
    assert entity.observed_at == nil
    assert %DateTime{} = entity.received_at
  end
end

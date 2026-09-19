defmodule Zaik.Home.AdapterCalibrationStoreTest do
  use ExUnit.Case, async: true

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "zaik-adapter-calibrations-#{System.unique_integer([:positive])}.db"
      )

    {:ok, store} =
      start_supervised({Zaik.Home.AdapterCalibrationStore, name: nil, db_path: db_path})

    on_exit(fn ->
      File.rm(db_path)
      File.rm(db_path <> "-shm")
      File.rm(db_path <> "-wal")
    end)

    %{store: store, db_path: db_path}
  end

  test "persists evidence-backed per-entity cover semantics with append-only revisions", %{
    store: store
  } do
    evidence = [
      %{
        type: "operator_observation",
        reference: "visual end-stop check",
        observed_at: ~U[2026-09-05 10:00:00Z]
      }
    ]

    assert {:ok, first} =
             Zaik.Home.AdapterCalibrationStore.put(
               "0xcover",
               "cover",
               "zigbee2mqtt",
               %{kind: "cover_position_linear", reported_open: 0, reported_closed: 100},
               %{
                 calibrated_by: "household-owner",
                 reason: "Confirm installed motor orientation",
                 evidence: evidence
               },
               store
             )

    assert first["schema_version"] == 1
    assert first["revision"] == 1
    assert first["semantics"]["canonical_open"] == 0
    assert first["semantics"]["canonical_closed"] == 100

    assert first["evidence"] == [
             %{
               "type" => "operator_observation",
               "reference" => "visual end-stop check",
               "observed_at" => "2026-09-05T10:00:00Z"
             }
           ]

    assert byte_size(first["evidence_fingerprint"]) == 64
    assert byte_size(first["calibration_fingerprint"]) == 64

    assert {:ok, second} =
             Zaik.Home.AdapterCalibrationStore.put(
               "0xcover",
               "cover",
               "zigbee2mqtt",
               %{
                 kind: "cover_position_linear",
                 reported_open: 100,
                 reported_closed: 0
               },
               %{
                 calibrated_by: "service-technician",
                 reason: "Motor firmware now reports an inverted scale",
                 evidence: [
                   %{
                     type: "physical_measurement",
                     reference: "commissioning sheet 2",
                     observed_at: "2026-09-06T11:30:00Z"
                   }
                 ]
               },
               store
             )

    assert second["revision"] == 2
    assert second["created_at"] == first["created_at"]
    refute second["calibration_fingerprint"] == first["calibration_fingerprint"]

    assert {:ok, ^second} =
             Zaik.Home.AdapterCalibrationStore.get(
               "0xcover",
               "cover",
               "zigbee2mqtt",
               store
             )

    assert [^second] = Zaik.Home.AdapterCalibrationStore.list([capability: "cover"], store)

    assert [history_first, history_second] =
             Zaik.Home.AdapterCalibrationStore.history(
               "0xcover",
               "cover",
               "zigbee2mqtt",
               store
             )

    assert history_first["revision"] == 1
    assert history_second["revision"] == 2
    assert history_first["calibrated_by"] == "household-owner"
  end

  test "fails closed without physical evidence, operator identity, or valid semantics", %{
    store: store
  } do
    calibration = %{kind: "cover_position_linear", reported_open: 0, reported_closed: 100}

    assert {:error, :missing_calibration_evidence} =
             Zaik.Home.AdapterCalibrationStore.put(
               "0xcover",
               "cover",
               "zigbee2mqtt",
               calibration,
               %{calibrated_by: "operator", reason: "test", evidence: []},
               store
             )

    attrs = %{
      calibrated_by: "operator",
      reason: "test",
      evidence: [
        %{
          type: "operator_observation",
          reference: "visual check",
          observed_at: ~U[2026-09-05 10:00:00Z]
        }
      ]
    }

    assert {:error, :degenerate_cover_calibration} =
             Zaik.Home.AdapterCalibrationStore.put(
               "0xcover",
               "cover",
               "zigbee2mqtt",
               %{kind: "cover_position_linear", reported_open: 50, reported_closed: 50},
               attrs,
               store
             )

    assert {:error, {:unknown_calibration_capability, "unknown"}} =
             Zaik.Home.AdapterCalibrationStore.put(
               "0xcover",
               "unknown",
               "zigbee2mqtt",
               calibration,
               attrs,
               store
             )

    assert [] = Zaik.Home.AdapterCalibrationStore.list([], store)
  end

  test "public configuration resolves a canonical entity before persistence", %{store: store} do
    {:ok, devices} = start_supervised({Zaik.Home.DeviceStore, name: nil})

    Zaik.Home.DeviceStore.upsert_device(
      devices,
      "Nursery blind",
      %{"position" => 0},
      %{"ieee_address" => "0xnursery-cover", "source" => "zigbee2mqtt"}
    )

    assert {:ok, calibration} =
             Zaik.configure_home_adapter_calibration(
               "nursery blind",
               "cover",
               "zigbee2mqtt",
               %{kind: "cover_position_linear", reported_open: 0, reported_closed: 100},
               %{
                 calibrated_by: "operator",
                 reason: "Installation commissioning",
                 evidence: [
                   %{
                     type: "manufacturer_documentation",
                     reference: "installation sheet revision A",
                     observed_at: ~U[2026-09-05 10:00:00Z]
                   }
                 ]
               },
               device_store: devices,
               calibration_store: store
             )

    assert calibration["entity_id"] == "0xnursery-cover"

    assert {:error, :not_found} =
             Zaik.configure_home_adapter_calibration(
               "missing blind",
               "cover",
               "zigbee2mqtt",
               %{kind: "cover_position_linear", reported_open: 0, reported_closed: 100},
               %{},
               device_store: devices,
               calibration_store: store
             )
  end
end

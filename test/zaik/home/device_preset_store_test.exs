defmodule Zaik.Home.DevicePresetStoreTest do
  use ExUnit.Case, async: true

  setup do
    db_path =
      Path.join(System.tmp_dir!(), "zaik-device-presets-#{System.unique_integer([:positive])}.db")

    {:ok, store} = start_supervised({Zaik.Home.DevicePresetStore, name: nil, db_path: db_path})
    on_exit(fn -> File.rm(db_path) end)
    %{store: store, db_path: db_path}
  end

  test "stores and lists generic named device targets", %{store: store} do
    assert {:ok, preset} =
             Zaik.Home.DevicePresetStore.put(
               "Lily's bedroom right blind",
               "above AC",
               "cover",
               %{"position" => 71},
               %{source: "test"},
               store
             )

    assert preset["target"] == %{"position" => 71}
    assert preset["capability"] == "cover"
    assert preset["preset_name"] == "above AC"

    assert {:ok, fetched} =
             Zaik.Home.DevicePresetStore.get(
               "Lilys bedroom right blind",
               "above ac",
               [capability: "cover"],
               store
             )

    assert fetched["device_name"] == "Lily's bedroom right blind"

    assert [^fetched] =
             Zaik.Home.DevicePresetStore.list(
               "Lily's bedroom right blind",
               [capability: "cover"],
               store
             )
  end

  test "rejects empty targets", %{store: store} do
    assert {:error, :empty_target} =
             Zaik.Home.DevicePresetStore.put("blind", "bad", "cover", %{}, %{}, store)
  end

  test "migrates legacy blind preset JSON into generic cover targets" do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "zaik-device-presets-legacy-#{System.unique_integer([:positive])}.db"
      )

    legacy_path =
      Path.join(
        System.tmp_dir!(),
        "zaik-legacy-blind-presets-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      legacy_path,
      Jason.encode!([
        %{
          "device_name" => "Lily's bedroom right blind",
          "preset_name" => "above AC",
          "position" => 71,
          "source" => "capture",
          "created_at" => "2026-09-04T19:15:25Z"
        }
      ])
    )

    child =
      Supervisor.child_spec(
        {Zaik.Home.DevicePresetStore,
         name: nil, db_path: db_path, legacy_blind_presets_path: legacy_path},
        id: {:legacy_device_preset_store, make_ref()}
      )

    {:ok, store} = start_supervised(child)

    assert {:ok, preset} =
             Zaik.Home.DevicePresetStore.get(
               "Lily's bedroom right blind",
               "above AC",
               [capability: "cover"],
               store
             )

    assert preset["target"] == %{"position" => 71}
    assert preset["metadata"]["legacy_store"] == "blind_presets.json"

    File.rm(db_path)
    File.rm(legacy_path)
  end
end

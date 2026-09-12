defmodule Zaik.Home.DevicePresetToolsTest do
  use ExUnit.Case, async: true

  defmodule FakeCoverExecutor do
    @behaviour Zaik.Home.Executor
    def capability, do: "cover"

    def prepare(entity, %{"preset" => name}, context) do
      with {:ok, preset} <-
             Zaik.Home.DevicePresetStore.get(
               entity.name,
               name,
               [capability: "cover"],
               context.preset_store
             ) do
        {:ok, preset["target"]}
      end
    end

    def execute(entity, target, context) do
      send(context.test_pid, {:applied, entity.id, target})
      {:ok, %{status: "accepted", target: target}}
    end
  end

  setup do
    now = ~U[2026-07-15 14:00:00Z]
    {:ok, clock} = start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: now})

    {:ok, devices} =
      start_supervised(
        {Zaik.Home.DeviceStore,
         name: nil, clock: {Zaik.Home.Mirror.Clock, clock}, event_bus: false}
      )

    {:ok, history} = start_supervised({Zaik.Home.HistoryStore, name: nil, db_path: ":memory:"})

    {:ok, presets} =
      start_supervised(
        {Zaik.Home.DevicePresetStore,
         name: nil, db_path: ":memory:", import_legacy_blind_presets?: false}
      )

    Zaik.Home.DeviceStore.upsert_device(devices, "Office blind", %{"position" => 71}, %{
      "ieee_address" => "blind",
      "area_id" => "office",
      "observed_at" => now,
      "source" => "test"
    })

    context = %{
      clock: {Zaik.Home.Mirror.Clock, clock},
      device_store: devices,
      history_store: history,
      preset_store: presets,
      sender_id: "operator"
    }

    %{clock: clock, devices: devices, history: history, presets: presets, context: context}
  end

  test "captures fresh canonical cover state without adapter payloads", context do
    assert {:ok, preset} =
             Zaik.Home.Tools.CaptureDevicePreset.run(
               %{"device" => "Office blind", "capability" => "cover", "preset" => "airflow"},
               context.context
             )

    assert preset["target"] == %{"position" => 71}
    assert preset["source"] == "capture"
    assert preset["created_by"] == "operator"
    assert preset["metadata"]["entity_id"] == "blind"
  end

  test "capture blocks stale observations", context do
    Zaik.Home.Mirror.Clock.advance(context.clock, 121_000)

    assert {:error, :stale_state} =
             Zaik.Home.Tools.CaptureDevicePreset.run(
               %{"device" => "Office blind", "capability" => "cover", "preset" => "stale"},
               context.context
             )
  end

  test "apply delegates the preset through validated capability execution", context do
    {:ok, _} =
      Zaik.Home.DevicePresetStore.put(
        "Office blind",
        "open",
        "cover",
        %{"position" => 0},
        %{},
        context.presets
      )

    assert {:ok, %{status: "accepted", target: %{"position" => 0}}} =
             Zaik.Home.Tools.ApplyDevicePreset.run(
               %{"device" => "Office blind", "capability" => "cover", "preset" => "open"},
               context.context
               |> Map.put(:executor_opts, modules: [FakeCoverExecutor])
               |> Map.put(:test_pid, self())
             )

    assert_received {:applied, "blind", %{"position" => 0}}
  end
end

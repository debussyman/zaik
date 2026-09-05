defmodule Zaik.Home.ControlDeviceTest do
  use ExUnit.Case, async: true

  defmodule FakeCoverExecutor do
    @behaviour Zaik.Home.Executor

    def capability, do: "cover"

    def execute(entity, target, context) do
      send(context.test_pid, {:executed, entity.id, target})

      {:ok,
       %{
         entity_id: entity.id,
         capability: "cover",
         target: target,
         status: "accepted",
         verified: false
       }}
    end
  end

  setup do
    {:ok, store} = start_supervised({Zaik.Home.DeviceStore, name: nil})

    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Office blind",
      %{"position" => 60, "state" => "STOP"},
      %{"ieee_address" => "0xoffice", "area_id" => "office"}
    )

    %{store: store}
  end

  test "resolves, validates, and dispatches a semantic capability target", %{store: store} do
    context = %{
      device_store: store,
      executor_opts: [modules: [FakeCoverExecutor]],
      test_pid: self()
    }

    assert {:ok, result} =
             Zaik.Tools.Registry.run(
               "control_device",
               %{
                 "device" => "0xoffice",
                 "capability" => "cover",
                 "target" => %{"position" => 37}
               },
               context
             )

    assert result.status == "accepted"
    assert result.verified == false
    assert_received {:executed, "0xoffice", %{"position" => 37}}
  end

  test "rejects invalid targets before invoking an executor", %{store: store} do
    context = %{
      device_store: store,
      executor_opts: [modules: [FakeCoverExecutor]],
      test_pid: self()
    }

    assert {:error, :invalid_cover_target} =
             Zaik.Tools.Registry.run(
               "control_device",
               %{
                 "device" => "Office blind",
                 "capability" => "cover",
                 "target" => %{"position" => 101}
               },
               context
             )

    refute_received {:executed, _entity_id, _target}
  end

  test "read-only capabilities cannot acquire targets", %{store: store} do
    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Office sensor",
      %{"temperature" => 22.0},
      %{"ieee_address" => "0xtemp", "area_id" => "office"}
    )

    assert {:error, :read_only_capability} =
             Zaik.Tools.Registry.run(
               "control_device",
               %{
                 "device" => "Office sensor",
                 "capability" => "temperature",
                 "target" => %{"celsius" => 20}
               },
               %{device_store: store}
             )
  end
end

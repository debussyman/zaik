defmodule Zaik.Home.ModeToolsTest do
  use ExUnit.Case, async: true

  setup do
    now = ~U[2026-07-15 20:00:00Z]
    {:ok, clock} = start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: now})
    {:ok, devices} = start_supervised({Zaik.Home.DeviceStore, name: nil})
    {:ok, history} = start_supervised({Zaik.Home.HistoryStore, name: nil, db_path: ":memory:"})

    {:ok, modes} =
      start_supervised(
        {Zaik.Home.Autonomy.ModeStore, name: nil, db_path: ":memory:", event_bus: false}
      )

    Zaik.Home.DeviceStore.upsert_device(
      devices,
      "Lily's room sensor",
      %{"presence" => true},
      %{
        "ieee_address" => "sensor",
        "area_id" => "lily_bedroom",
        "observed_at" => now,
        "source" => "test"
      }
    )

    context = %{
      clock: {Zaik.Home.Mirror.Clock, clock},
      device_store: devices,
      history_store: history,
      mode_store: modes,
      sender_id: "parent"
    }

    %{context: context, modes: modes}
  end

  test "activates, lists, and cancels a mode through registered semantic tools", context do
    assert {:ok, lease} =
             Zaik.Tools.Registry.run(
               "activate_home_mode",
               %{
                 "scope" => "Lily's room",
                 "mode" => "privacy",
                 "ttl_seconds" => 600,
                 "reason" => "guests"
               },
               context.context
             )

    assert lease.scope == "lily_bedroom"
    assert lease.owner == "parent"
    assert lease.source == "agent_tool"

    assert {:ok, %{count: 1, modes: [%{id: id}], scope: "lily_bedroom"}} =
             Zaik.Tools.Registry.run(
               "get_home_modes",
               %{"scope" => "Lily's room"},
               context.context
             )

    assert id == lease.id

    assert {:ok, %{status: "cancelled", cancelled_by: "parent"}} =
             Zaik.Tools.Registry.run(
               "cancel_home_mode",
               %{"mode_id" => lease.id},
               context.context
             )
  end

  test "rejects unresolved scopes and unbounded leases", context do
    assert {:error, {:home_mode_scope_not_found, "garage"}} =
             Zaik.Home.Tools.ActivateMode.run(
               %{"scope" => "garage", "mode" => "privacy", "ttl_seconds" => 60},
               context.context
             )

    assert {:error, :invalid_home_mode_ttl} =
             Zaik.Home.Tools.ActivateMode.run(
               %{"scope" => "home", "mode" => "privacy", "ttl_seconds" => 100_000},
               context.context
             )
  end
end

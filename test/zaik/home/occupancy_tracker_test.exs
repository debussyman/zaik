defmodule Zaik.Home.OccupancyTrackerTest do
  use ExUnit.Case, async: true

  setup do
    now = ~U[2026-07-15 14:00:00Z]
    {:ok, clock} = start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: now})
    {:ok, bus} = start_supervised({Zaik.Home.EventBus, name: nil})

    {:ok, tracker} =
      start_supervised(
        {Zaik.Home.OccupancyTracker,
         name: nil,
         event_bus: bus,
         clock: {Zaik.Home.Mirror.Clock, clock},
         absence_debounce_ms: 1_000}
      )

    %{now: now, clock: clock, bus: bus, tracker: tracker}
  end

  test "resolves persisted area when adapter metadata omits it", context do
    {:ok, devices} = start_supervised({Zaik.Home.DeviceStore, name: nil, event_bus: false})
    {:ok, history} = start_supervised({Zaik.Home.HistoryStore, name: nil, db_path: ":memory:"})

    Zaik.Home.DeviceStore.upsert_device(
      devices,
      "Room sensor",
      %{"presence" => true},
      %{"ieee_address" => "area-sensor", "observed_at" => context.now}
    )

    :ok =
      Zaik.Home.HistoryStore.record_device(
        history,
        "Room sensor",
        %{"presence" => true},
        %{"ieee_address" => "area-sensor", "area_id" => "resolved_room"},
        observed_at: context.now
      )

    {:ok, tracker} =
      start_supervised(
        {Zaik.Home.OccupancyTracker,
         name: nil,
         event_bus: context.bus,
         clock: {Zaik.Home.Mirror.Clock, context.clock},
         device_store: devices,
         identity_store: history},
        id: :resolved_area_tracker
      )

    Zaik.Home.EventBus.publish(
      %{
        type: :device_observed,
        device: "Room sensor",
        payload: %{"presence" => true},
        metadata: %{},
        changed_keys: ["presence"],
        observed_at: context.now
      },
      context.bus
    )

    assert_eventually(fn ->
      Zaik.Home.OccupancyTracker.status("resolved_room", tracker).status == "occupied"
    end)
  end

  test "presence transitions through entered, possibly absent, and debounced vacant", context do
    publish(context, "sensor-1", true)

    assert_eventually(fn ->
      Zaik.Home.OccupancyTracker.status("lily_bedroom", context.tracker).status == "occupied"
    end)

    occupied = Zaik.Home.OccupancyTracker.status("lily_bedroom", context.tracker)
    assert occupied.transition == "entered"
    assert occupied.confidence == 1.0

    publish(context, "sensor-1", false)

    assert_eventually(fn ->
      Zaik.Home.OccupancyTracker.status("lily_bedroom", context.tracker).status ==
        "possibly_absent"
    end)

    Zaik.Home.Mirror.Clock.advance(context.clock, 999)

    assert Zaik.Home.OccupancyTracker.status("lily_bedroom", context.tracker).status ==
             "possibly_absent"

    Zaik.Home.Mirror.Clock.advance(context.clock, 1)

    assert_eventually(fn ->
      Zaik.Home.OccupancyTracker.status("lily_bedroom", context.tracker).status == "vacant"
    end)
  end

  test "new presence invalidates a pending absence timer", context do
    publish(context, "sensor-1", true)

    assert_eventually(fn ->
      Zaik.Home.OccupancyTracker.status("lily_bedroom", context.tracker).status == "occupied"
    end)

    publish(context, "sensor-1", false)

    assert_eventually(fn ->
      Zaik.Home.OccupancyTracker.status("lily_bedroom", context.tracker).status ==
        "possibly_absent"
    end)

    publish(context, "sensor-1", true)

    assert_eventually(fn ->
      Zaik.Home.OccupancyTracker.status("lily_bedroom", context.tracker).status == "occupied"
    end)

    Zaik.Home.Mirror.Clock.advance(context.clock, 1_000)
    Process.sleep(2)
    assert Zaik.Home.OccupancyTracker.status("lily_bedroom", context.tracker).status == "occupied"
  end

  test "one negative sensor cannot vacate an area with another positive sensor", context do
    publish(context, "sensor-1", true)
    publish(context, "sensor-2", true)

    assert_eventually(fn ->
      Zaik.Home.OccupancyTracker.status("lily_bedroom", context.tracker).evidence_count == 2
    end)

    publish(context, "sensor-1", false)

    assert_eventually(fn ->
      Zaik.Home.OccupancyTracker.status("lily_bedroom", context.tracker).evidence_count == 1
    end)

    occupancy = Zaik.Home.OccupancyTracker.status("lily_bedroom", context.tracker)
    assert occupancy.status == "occupied"
    assert occupancy.transition == "occupied"
  end

  defp publish(context, device, detected) do
    Zaik.Home.EventBus.publish(
      %{
        type: :device_observed,
        device: device,
        payload: %{"presence" => detected},
        metadata: %{"area_id" => "lily_bedroom"},
        changed_keys: ["presence"],
        observed_at: context.now
      },
      context.bus
    )
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(2)
          assert_eventually(fun, attempts - 1)
        )
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end

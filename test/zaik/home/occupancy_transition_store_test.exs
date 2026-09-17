defmodule Zaik.Home.OccupancyTransitionStoreTest do
  use ExUnit.Case, async: true

  setup do
    now = ~U[2026-07-15 14:00:00Z]
    {:ok, clock} = start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: now})
    {:ok, bus} = start_supervised({Zaik.Home.EventBus, name: nil})

    db_path =
      Path.join(
        System.tmp_dir!(),
        "zaik-occupancy-transitions-#{System.unique_integer([:positive, :monotonic])}.db"
      )

    on_exit(fn -> Enum.each(Path.wildcard(db_path <> "*"), &File.rm/1) end)

    {:ok, store} =
      start_supervised(
        {Zaik.Home.OccupancyTransitionStore,
         name: nil, event_bus: bus, db_path: db_path, clock: {Zaik.Home.Mirror.Clock, clock}}
      )

    %{now: now, clock: clock, bus: bus, store: store}
  end

  test "persists meaningful occupancy projection transitions idempotently", context do
    entered = event("lily_bedroom", "unknown", "occupied", "entered", context.now)
    Zaik.Home.EventBus.publish(entered, context.bus)
    Zaik.Home.EventBus.publish(entered, context.bus)

    Zaik.Home.EventBus.publish(
      event("lily_bedroom", "occupied", "occupied", "occupied", context.now),
      context.bus
    )

    assert_eventually(fn ->
      case Zaik.Home.OccupancyTransitionStore.recent("lily_bedroom", [], context.store) do
        [%{previous_status: "unknown", status: "occupied", transition: "entered"}] -> true
        _ -> false
      end
    end)
  end

  test "summarizes cross-area entry order without claiming person identity", context do
    Zaik.Home.EventBus.publish(
      event("lily_bedroom", "vacant", "occupied", "entered", context.now),
      context.bus
    )

    later = DateTime.add(context.now, 90, :second)

    Zaik.Home.EventBus.publish(
      event("hallway", "vacant", "occupied", "entered", later),
      context.bus
    )

    assert_eventually(fn ->
      Zaik.Home.OccupancyTransitionStore.entry_sequences(
        [window_seconds: 120],
        context.store
      ) == [
        %{
          from_area: "lily_bedroom",
          to_area: "hallway",
          observations: 1,
          last_observed_at: DateTime.to_iso8601(later),
          maximum_gap_seconds: 90,
          semantics: "observed_entry_sequence_not_person_identity"
        }
      ]
    end)

    assert Zaik.Home.OccupancyTransitionStore.entry_sequences(
             [window_seconds: 30],
             context.store
           ) == []
  end

  test "records transitions emitted by the debounced occupancy tracker", context do
    {:ok, tracker} =
      start_supervised(
        {Zaik.Home.OccupancyTracker,
         name: nil,
         event_bus: context.bus,
         clock: {Zaik.Home.Mirror.Clock, context.clock},
         absence_debounce_ms: 1_000},
        id: :transition_tracker
      )

    Zaik.Home.EventBus.publish(
      %{
        type: :device_observed,
        device: "presence sensor",
        payload: %{"presence" => true},
        metadata: %{"area_id" => "lily_bedroom"},
        changed_keys: ["presence"],
        observed_at: context.now
      },
      context.bus
    )

    assert_eventually(fn ->
      match?(
        [%{transition: "entered", previous_status: "unknown", evidence_count: 1}],
        Zaik.Home.OccupancyTransitionStore.recent("lily_bedroom", [], context.store)
      )
    end)

    assert Zaik.Home.OccupancyTracker.status("lily_bedroom", tracker).status == "occupied"
  end

  defp event(area, previous, status, transition, time) do
    %{
      type: :occupancy_changed,
      area: area,
      previous_status: previous,
      status: status,
      transition: transition,
      confidence: 1.0,
      evidence_count: 1,
      observed_at: DateTime.to_iso8601(time),
      transitioned_at: DateTime.to_iso8601(time)
    }
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(2)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end

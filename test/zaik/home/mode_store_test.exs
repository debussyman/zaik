defmodule Zaik.Home.ModeStoreTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, clock} =
      start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: ~U[2026-07-15 20:00:00Z]})

    {:ok, bus} = start_supervised({Zaik.Home.EventBus, name: nil})
    :ok = Zaik.Home.EventBus.subscribe(bus, self())

    {:ok, store} =
      start_supervised(
        {Zaik.Home.Autonomy.ModeStore,
         name: nil, db_path: ":memory:", clock: {Zaik.Home.Mirror.Clock, clock}, event_bus: bus}
      )

    %{clock: clock, bus: bus, store: store}
  end

  test "activates, supersedes, expires, and audits typed modes", context do
    opts = [clock: {Zaik.Home.Mirror.Clock, context.clock}]

    assert {:ok, first} =
             Zaik.Home.Autonomy.ModeStore.activate(
               "lily_bedroom",
               :bedtime,
               %{owner: "parent", reason: "sleep", ttl_seconds: 60},
               opts,
               context.store
             )

    assert_receive {:zaik_home_event,
                    %{type: :home_mode_changed, area: "lily_bedroom", mode: "bedtime"}}

    assert [%{id: id, mode: "bedtime", status: "active"}] =
             Zaik.Home.Autonomy.ModeStore.active("lily_bedroom", opts, context.store)

    assert id == first.id

    assert {:ok, second} =
             Zaik.Home.Autonomy.ModeStore.activate(
               "lily_bedroom",
               "bedtime",
               %{owner: "parent", reason: "later bedtime", ttl_seconds: 120},
               opts,
               context.store
             )

    assert second.id != first.id

    assert {:ok, %{status: "superseded"}} =
             Zaik.Home.Autonomy.ModeStore.lookup(first.id, context.store)

    assert {:ok, cancelled} =
             Zaik.Home.Autonomy.ModeStore.cancel(second.id, "parent", opts, context.store)

    assert cancelled.status == "cancelled"
    assert cancelled.cancelled_by == "parent"
    assert Zaik.Home.Autonomy.ModeStore.active("lily_bedroom", opts, context.store) == []

    assert {:ok, privacy} =
             Zaik.Home.Autonomy.ModeStore.activate(
               "home",
               "privacy",
               %{ttl_seconds: 30},
               opts,
               context.store
             )

    assert [%{id: privacy_id}] =
             Zaik.Home.Autonomy.ModeStore.active("main_bedroom", opts, context.store)

    assert privacy_id == privacy.id
    Zaik.Home.Mirror.Clock.advance(context.clock, 30_000)
    assert Zaik.Home.Autonomy.ModeStore.active("main_bedroom", opts, context.store) == []
  end

  test "rejects unsupported modes", context do
    assert {:error, {:unsupported_home_mode, "party"}} =
             Zaik.Home.Autonomy.ModeStore.activate(
               "room",
               "party",
               %{},
               [],
               context.store
             )
  end
end

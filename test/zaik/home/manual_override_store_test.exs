defmodule Zaik.Home.ManualOverrideStoreTest do
  use ExUnit.Case, async: true

  setup do
    now = ~U[2026-07-15 14:00:00Z]
    {:ok, clock} = start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: now})

    {:ok, store} =
      start_supervised({Zaik.Home.Autonomy.ManualOverrideStore, name: nil, db_path: ":memory:"})

    %{clock: clock, store: store, now: now}
  end

  test "leases retain scope, ownership, reason, capability, and expiry", context do
    assert {:ok, lease} =
             Zaik.Home.Autonomy.ManualOverrideStore.create(
               "Lily_Bedroom",
               %{
                 owner: "ryan",
                 reason: "opened manually",
                 capability: "cover",
                 ttl_seconds: 600
               },
               [clock: {Zaik.Home.Mirror.Clock, context.clock}],
               context.store
             )

    assert lease.scope == "lily_bedroom"
    assert lease.owner == "ryan"
    assert lease.reason == "opened manually"
    assert lease.capability == "cover"
    assert lease.status == "active"
    assert lease.expires_at == "2026-07-15T14:10:00Z"

    assert [active] =
             Zaik.Home.Autonomy.ManualOverrideStore.active(
               "lily_bedroom",
               [capability: "cover", clock: {Zaik.Home.Mirror.Clock, context.clock}],
               context.store
             )

    assert active.id == lease.id

    assert Zaik.Home.Autonomy.ManualOverrideStore.active(
             "main_bedroom",
             [clock: {Zaik.Home.Mirror.Clock, context.clock}],
             context.store
           ) == []
  end

  test "expiry and cancellation suppress only while the lease is active", context do
    opts = [clock: {Zaik.Home.Mirror.Clock, context.clock}]

    assert {:ok, lease} =
             Zaik.Home.Autonomy.ManualOverrideStore.create(
               "home",
               %{owner: "family", reason: "quiet time", ttl_seconds: 10},
               opts,
               context.store
             )

    assert [_] =
             Zaik.Home.Autonomy.ManualOverrideStore.active(
               "any_room",
               opts,
               context.store
             )

    Zaik.Home.Mirror.Clock.advance(context.clock, 10_000)
    assert [] = Zaik.Home.Autonomy.ManualOverrideStore.active("any_room", opts, context.store)

    assert {:ok, cancelled} =
             Zaik.Home.Autonomy.ManualOverrideStore.cancel(
               lease.id,
               "ryan",
               opts,
               context.store
             )

    assert cancelled.status == "cancelled"
    assert cancelled.cancelled_by == "ryan"
    assert cancelled.cancelled_at == "2026-07-15T14:00:10.000Z"
  end
end

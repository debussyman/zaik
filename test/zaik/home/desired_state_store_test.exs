defmodule Zaik.Home.DesiredStateStoreTest do
  use ExUnit.Case, async: true

  setup do
    now = ~U[2026-07-15 14:00:00Z]
    {:ok, clock} = start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: now})

    {:ok, store} =
      start_supervised(
        {Zaik.Home.Autonomy.DesiredStateStore,
         name: nil, db_path: ":memory:", clock: {Zaik.Home.Mirror.Clock, clock}}
      )

    %{now: now, clock: clock, store: store}
  end

  test "stores active leases, supersedes conflicts, and expires under virtual time", context do
    assert {:ok, [first]} =
             Zaik.Home.Autonomy.DesiredStateStore.record(
               decision("one", 0, context.now),
               context.store
             )

    assert first.status == "active"
    assert first.priority_class == "daylight_energy"

    assert {:ok, [second]} =
             Zaik.Home.Autonomy.DesiredStateStore.record(
               decision("two", 100, context.now),
               context.store
             )

    assert second.status == "active"

    assert [%{id: id, target: %{"position" => 100}}] =
             Zaik.Home.Autonomy.DesiredStateStore.active(
               "room",
               [clock: {Zaik.Home.Mirror.Clock, context.clock}],
               context.store
             )

    assert id == second.id

    assert %{status: "superseded", id: first_id} =
             Enum.find(
               Zaik.Home.Autonomy.DesiredStateStore.recent(10, context.store),
               &(&1.id == first.id)
             )

    assert first_id == first.id

    Zaik.Home.Mirror.Clock.advance(context.clock, 60_000)

    assert Zaik.Home.Autonomy.DesiredStateStore.active(
             "room",
             [clock: {Zaik.Home.Mirror.Clock, context.clock}],
             context.store
           ) == []
  end

  defp decision(id, position, now) do
    %{
      id: "decision-#{id}",
      snapshot_id: "snapshot-#{id}",
      policy_fingerprint: "registry",
      created_at: now,
      context: %{areas: ["room"]},
      arbitration: %{
        selected: [
          %{
            candidate_id: "candidate-#{id}",
            entity_id: "blind",
            device: "Room blind",
            capability: "cover",
            target: %{"position" => position},
            policy_id: "policy-#{id}",
            policy_version: "1",
            priority_class: :daylight_energy,
            priority: 40,
            confidence: 0.8,
            evidence: %{snapshot_id: "snapshot-#{id}"},
            expires_at: DateTime.add(now, 60, :second) |> DateTime.to_iso8601()
          }
        ]
      }
    }
  end
end

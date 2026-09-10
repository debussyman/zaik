defmodule Zaik.Home.ReconcilerTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, clock} =
      start_supervised(
        {Zaik.Home.Mirror.Clock, name: nil, now: ~U[2026-07-15 20:00:00Z]},
        id: :reconciler_clock
      )

    %{clock: clock}
  end

  test "emits only unresolved fresh desired state", %{clock: clock} do
    desired = [
      selected("left", "Left blind", %{"position" => 100}),
      selected("right", "Right blind", %{"position" => 71})
    ]

    context = %{
      entities: [
        entity("left", "Left blind", 100, ~U[2026-07-15 19:59:30Z]),
        entity("right", "Right blind", 0, ~U[2026-07-15 19:59:30Z])
      ]
    }

    result =
      Zaik.Home.Reconciler.diff(%{selected: desired}, context,
        clock: {Zaik.Home.Mirror.Clock, clock}
      )

    assert [%{device: "Right blind", target: %{"position" => 71}}] = result.actions
    assert [%{entity_id: "left"}] = result.satisfied
    assert result.blocked == []
    assert byte_size(result.fingerprint) == 64
  end

  test "blocks stale or missing observations instead of guessing", %{clock: clock} do
    desired = [
      selected("stale", "Stale blind", %{"position" => 0}),
      selected("missing", "Missing blind", %{"position" => 0})
    ]

    context = %{
      entities: [entity("stale", "Stale blind", 100, ~U[2026-07-15 19:55:00Z])]
    }

    result =
      Zaik.Home.Reconciler.diff(%{selected: desired}, context,
        clock: {Zaik.Home.Mirror.Clock, clock},
        max_state_age_seconds: 120
      )

    assert result.actions == []
    assert result.satisfied == []

    assert Enum.map(result.blocked, & &1.reason) |> Enum.sort() == [
             "entity_not_found",
             "observation_stale"
           ]
  end

  defp selected(id, name, target) do
    %{
      entity_id: id,
      device: name,
      capability: "cover",
      target: target,
      candidate_id: "candidate",
      policy_id: "policy"
    }
  end

  defp entity(id, name, position, observed_at) do
    %{
      id: id,
      name: name,
      observed_at: DateTime.to_iso8601(observed_at),
      state: %{"cover" => %{position: position}}
    }
  end
end

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

  test "enforces policy settle and cooldown windows before emitting actions", %{clock: clock} do
    now = ~U[2026-07-15 20:00:00Z]
    desired = selected("left", "Left blind", %{"position" => 0}, 30, 120)
    entity = entity("left", "Left blind", 100, ~U[2026-07-15 19:59:30Z])

    opts = [
      clock: {Zaik.Home.Mirror.Clock, clock},
      policy_stability: %{"policy" => %{settle_seconds: 30, cooldown_seconds: 120}}
    ]

    first = Zaik.Home.Reconciler.diff(%{selected: [desired]}, %{entities: [entity]}, opts)
    assert [%{reason: "policy_settling", retry_after_seconds: 30}] = first.blocked

    lease = lease(desired, "active", now, DateTime.add(now, 120, :second))

    settling =
      Zaik.Home.Reconciler.diff(
        %{selected: [desired]},
        %{entities: [entity], desired_state_leases: [lease], desired_state_history: [lease]},
        opts
      )

    assert [%{reason: "policy_settling", retry_after_seconds: 30}] = settling.blocked

    Zaik.Home.Mirror.Clock.advance(clock, 31_000)

    ready =
      Zaik.Home.Reconciler.diff(
        %{selected: [desired]},
        %{entities: [entity], desired_state_leases: [lease], desired_state_history: [lease]},
        opts
      )

    assert [%{device: "Left blind"}] = ready.actions

    expired =
      lease(desired, "active", DateTime.add(now, -180, :second), DateTime.add(now, -60, :second))

    cooldown =
      Zaik.Home.Reconciler.diff(
        %{selected: [desired]},
        %{entities: [entity], desired_state_leases: [], desired_state_history: [expired]},
        clock: {Zaik.Home.Mirror.Clock, clock},
        policy_stability: %{"policy" => %{settle_seconds: 30, cooldown_seconds: 120}}
      )

    assert [%{reason: "policy_cooldown", retry_after_seconds: 29}] = cooldown.blocked
  end

  test "stability windows never block an already converged target", %{clock: clock} do
    desired = selected("left", "Left blind", %{"position" => 0}, 30, 120)
    context = %{entities: [entity("left", "Left blind", 0, ~U[2026-07-15 19:59:30Z])]}

    result =
      Zaik.Home.Reconciler.diff(%{selected: [desired]}, context,
        clock: {Zaik.Home.Mirror.Clock, clock}
      )

    assert result.blocked == []
    assert [%{entity_id: "left"}] = result.satisfied
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

  defp selected(id, name, target, settle_seconds \\ 0, cooldown_seconds \\ 0) do
    %{
      entity_id: id,
      device: name,
      capability: "cover",
      target: target,
      candidate_id: "candidate",
      policy_id: "policy",
      evidence: %{
        thresholds: %{settle_seconds: settle_seconds, cooldown_seconds: cooldown_seconds}
      }
    }
  end

  defp lease(desired, status, created_at, expires_at) do
    %{
      source_id: desired.policy_id,
      entity_id: desired.entity_id,
      capability: desired.capability,
      target: desired.target,
      status: status,
      created_at: DateTime.to_iso8601(created_at),
      expires_at: DateTime.to_iso8601(expires_at),
      superseded_at: nil
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

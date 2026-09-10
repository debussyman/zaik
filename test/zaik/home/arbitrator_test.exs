defmodule Zaik.Home.ArbitratorTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, clock} =
      start_supervised(
        {Zaik.Home.Mirror.Clock, name: nil, now: ~U[2026-07-15 20:00:00Z]},
        id: :arbitrator_clock
      )

    %{clock: clock}
  end

  test "higher-priority bedtime target suppresses daylight target", %{clock: clock} do
    daylight = candidate("daylight", 40, %{"state" => "OPEN"}, clock)
    bedtime = candidate("bedtime", 80, %{"state" => "CLOSE"}, clock)

    result =
      Zaik.Home.Arbitrator.arbitrate([daylight, bedtime],
        clock: {Zaik.Home.Mirror.Clock, clock}
      )

    assert [selected] = result.selected
    assert selected.policy_id == "bedtime"
    assert selected.target == %{"position" => 100}

    assert [suppressed] = result.suppressed
    assert suppressed.candidate_id == daylight.id
    assert suppressed.reason == "conflicting_lower_priority"
    assert suppressed.selected_candidate_id == bedtime.id
    assert byte_size(result.fingerprint) == 64
  end

  test "equivalent targets coalesce and expired candidates cannot win", %{clock: clock} do
    first = candidate("policy_a", 40, %{"state" => "OPEN"}, clock)
    equivalent = candidate("policy_b", 30, %{"position" => 0}, clock)
    expired = candidate("manual", 100, %{"state" => "CLOSE"}, clock, -1)

    result =
      Zaik.Home.Arbitrator.arbitrate([equivalent, expired, first],
        clock: {Zaik.Home.Mirror.Clock, clock}
      )

    assert [%{policy_id: "policy_a", target: %{"position" => 0}}] = result.selected
    assert Enum.any?(result.suppressed, &(&1.reason == "equivalent_lower_priority"))
    assert Enum.any?(result.suppressed, &(&1.reason == "expired"))
  end

  defp candidate(policy_id, priority, target, clock, ttl \\ 120) do
    now = Zaik.Home.Mirror.Clock.now(clock)

    Zaik.Home.GoalCandidate.new!(%{
      policy_id: policy_id,
      policy_version: "1",
      scope: "lily_bedroom",
      priority: priority,
      desired_state: [
        %{
          entity_id: "left",
          device: "Lily's bedroom left blind",
          capability: "cover",
          target: target
        }
      ],
      evidence: %{snapshot_id: "snapshot"},
      reason: policy_id,
      created_at: if(ttl > 0, do: now, else: DateTime.add(now, -120, :second)),
      expires_at: DateTime.add(now, ttl, :second)
    })
  end
end

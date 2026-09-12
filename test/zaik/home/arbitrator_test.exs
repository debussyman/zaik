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

  test "household priority classes have fixed non-model-selected weights" do
    assert Zaik.Home.Priority.classes() == [
             safety_security: 100,
             explicit_user: 90,
             privacy_sleep: 80,
             comfort: 60,
             daylight_energy: 40
           ]

    assert {:error, {:priority_class_mismatch, :comfort, 60, 100}} =
             Zaik.Home.Priority.validate(:comfort, 100)
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

  test "confidence breaks ties within the same household priority", %{clock: clock} do
    low = candidate("policy_a", 40, %{"state" => "OPEN"}, clock, 120, 0.4)
    high = candidate("policy_b", 40, %{"state" => "CLOSE"}, clock, 120, 0.9)

    result = Zaik.Home.Arbitrator.arbitrate([low, high], clock: {Zaik.Home.Mirror.Clock, clock})

    assert [%{policy_id: "policy_b", confidence: 0.9}] = result.selected
    assert [%{candidate_id: low_id, reason: "conflicting_lower_priority"}] = result.suppressed
    assert low_id == low.id
  end

  test "equivalent targets coalesce and expired candidates cannot win", %{clock: clock} do
    first = candidate("policy_a", 40, %{"state" => "OPEN"}, clock)
    equivalent = candidate("policy_b", 40, %{"position" => 0}, clock)
    expired = candidate("manual", 100, %{"state" => "CLOSE"}, clock, -1)

    result =
      Zaik.Home.Arbitrator.arbitrate([equivalent, expired, first],
        clock: {Zaik.Home.Mirror.Clock, clock}
      )

    assert [%{policy_id: "policy_a", target: %{"position" => 0}}] = result.selected
    assert Enum.any?(result.suppressed, &(&1.reason == "equivalent_lower_priority"))
    assert Enum.any?(result.suppressed, &(&1.reason == "expired"))
  end

  defp candidate(policy_id, priority, target, clock, ttl \\ 120, confidence \\ 0.9) do
    now = Zaik.Home.Mirror.Clock.now(clock)

    Zaik.Home.GoalCandidate.new!(%{
      policy_id: policy_id,
      policy_version: "1",
      scope: "lily_bedroom",
      priority_class: priority_class(priority),
      priority: priority,
      confidence: confidence,
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

  defp priority_class(100), do: :safety_security
  defp priority_class(90), do: :explicit_user
  defp priority_class(80), do: :privacy_sleep
  defp priority_class(60), do: :comfort
  defp priority_class(40), do: :daylight_energy
end

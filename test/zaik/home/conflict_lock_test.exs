defmodule Zaik.Home.ConflictLockTest do
  use ExUnit.Case, async: true

  test "blocks equivalent and contradictory actions until pending expiry" do
    now = ~U[2026-07-15 12:00:00Z]

    pending = [
      %{
        action_id: "pending-left",
        device: "Left Blind",
        capability: "cover",
        target: %{"position" => 100},
        status: "pending",
        expires_at: DateTime.add(now, 30, :second) |> DateTime.to_iso8601()
      }
    ]

    result =
      Zaik.Home.Autonomy.ConflictLock.assess(
        [action("left blind", 100), action("LEFT BLIND", 0), action("right blind", 0)],
        pending,
        clock: fixed_clock(now)
      )

    assert result.status == "blocked"
    assert Enum.map(result.allowed, & &1.device) == ["right blind"]

    assert [equivalent, conflicting] = result.blocked
    assert equivalent.reason == "equivalent_action_pending"
    assert conflicting.reason == "conflicting_action_pending"
    assert equivalent.pending_action_id == "pending-left"
    assert equivalent.retry_after_seconds == 30
  end

  test "ignores terminal verifier records" do
    terminal = [
      %{
        action_id: "done",
        device: "left blind",
        capability: "cover",
        target: %{"position" => 100},
        status: "verified"
      }
    ]

    assert %{status: "clear", allowed: [_], blocked: []} =
             Zaik.Home.Autonomy.ConflictLock.assess([action("left blind", 0)], terminal)
  end

  defp action(device, position) do
    %{
      entity_id: device,
      device: device,
      capability: "cover",
      target: %{"position" => position}
    }
  end

  defp fixed_clock(now) do
    {:ok, clock} = start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: now})
    {Zaik.Home.Mirror.Clock, clock}
  end
end

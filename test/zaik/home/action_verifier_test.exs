defmodule Zaik.Home.ActionVerifierTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, verifier} =
      start_supervised(
        {Zaik.Home.ActionVerifier,
         name: nil, timeout_ms: 200, retention_ms: 1_000, position_tolerance: 2}
      )

    %{verifier: verifier}
  end

  test "verifies a cover position from a correlated later state report", %{verifier: verifier} do
    action_id = "position-action"

    assert {:ok, registered} =
             Zaik.Home.ActionVerifier.register(
               action_id,
               "Office blind",
               "cover",
               %{"position" => 37},
               server: verifier
             )

    assert registered.status == "registered"
    assert {:ok, pending} = Zaik.Home.ActionVerifier.published(action_id, server: verifier)
    assert pending.status == "pending"

    Zaik.Home.ActionVerifier.observe(
      "Office blind",
      %{"position" => 50},
      DateTime.utc_now(),
      server: verifier
    )

    assert %{verified: false, status: "pending"} =
             Zaik.Home.ActionVerifier.await(action_id, 10, server: verifier)

    Zaik.Home.ActionVerifier.observe(
      "Office blind",
      %{"position" => 38},
      DateTime.utc_now(),
      server: verifier
    )

    assert %{verified: true, status: "verified", observed: %{"position" => 38}} =
             Zaik.Home.ActionVerifier.await(action_id, 100, server: verifier)
  end

  test "requires endpoint convergence for open and close commands", %{verifier: verifier} do
    action_id = "close-action"

    assert {:ok, _} =
             Zaik.Home.ActionVerifier.register(
               action_id,
               "Office blind",
               "cover",
               %{"state" => "CLOSE"},
               server: verifier
             )

    assert {:ok, _} = Zaik.Home.ActionVerifier.published(action_id, server: verifier)

    Zaik.Home.ActionVerifier.observe(
      "Office blind",
      %{"state" => "CLOSE", "position" => 40},
      DateTime.utc_now(),
      server: verifier
    )

    assert %{verified: false} = Zaik.Home.ActionVerifier.await(action_id, 10, server: verifier)

    Zaik.Home.ActionVerifier.observe(
      "Office blind",
      %{"state" => "CLOSE", "position" => 99},
      DateTime.utc_now(),
      server: verifier
    )

    assert %{verified: true, observed: %{"position" => 99, "state" => "CLOSE"}} =
             Zaik.Home.ActionVerifier.await(action_id, 100, server: verifier)
  end

  test "does not use a state observation received before registration", %{verifier: verifier} do
    observed_at = DateTime.add(DateTime.utc_now(), -5, :second)

    Zaik.Home.ActionVerifier.observe(
      "Office blind",
      %{"position" => 25},
      observed_at,
      server: verifier
    )

    Process.sleep(5)

    assert {:ok, _} =
             Zaik.Home.ActionVerifier.register(
               "new-action",
               "Office blind",
               "cover",
               %{"position" => 25},
               server: verifier
             )

    assert {:ok, _} = Zaik.Home.ActionVerifier.published("new-action", server: verifier)

    assert %{verified: false, status: "pending"} =
             Zaik.Home.ActionVerifier.await("new-action", 10, server: verifier)
  end

  test "an older out-of-order observation cannot verify a pending target", %{verifier: verifier} do
    now = DateTime.utc_now()

    assert {:ok, _registered} =
             Zaik.Home.ActionVerifier.register(
               "ordered-action",
               "Office blind",
               "cover",
               %{"state" => "OPEN"},
               server: verifier
             )

    assert {:ok, _pending} =
             Zaik.Home.ActionVerifier.published("ordered-action", server: verifier)

    Zaik.Home.ActionVerifier.observe(
      "Office blind",
      %{"state" => "CLOSE", "position" => 100},
      DateTime.add(now, 10, :second),
      server: verifier
    )

    Zaik.Home.ActionVerifier.observe(
      "Office blind",
      %{"state" => "OPEN", "position" => 0},
      DateTime.add(now, 5, :second),
      server: verifier
    )

    Zaik.Home.ActionVerifier.barrier(verifier)

    assert {:ok, %{status: "pending", verified: false}} =
             Zaik.Home.ActionVerifier.status("ordered-action", server: verifier)
  end

  test "rejects a conflicting target while an action is pending", %{verifier: verifier} do
    assert {:ok, _registered} =
             Zaik.Home.ActionVerifier.register(
               "first-action",
               "Office blind",
               "cover",
               %{"state" => "CLOSE"},
               server: verifier
             )

    assert {:ok, _pending} =
             Zaik.Home.ActionVerifier.published("first-action", server: verifier)

    assert [
             %{
               action_id: "first-action",
               device: "Office blind",
               capability: "cover",
               status: "pending"
             }
           ] = Zaik.Home.ActionVerifier.pending(server: verifier)

    assert {:error, {:conflicting_action_pending, "first-action"}} =
             Zaik.Home.ActionVerifier.register(
               "second-action",
               "Office blind",
               "cover",
               %{"state" => "OPEN"},
               server: verifier
             )

    assert :ok = Zaik.Home.ActionVerifier.cancel("first-action", :operator, server: verifier)
    assert Zaik.Home.ActionVerifier.pending(server: verifier) == []

    assert {:ok, _registered} =
             Zaik.Home.ActionVerifier.register(
               "second-action",
               "Office blind",
               "cover",
               %{"state" => "OPEN"},
               server: verifier
             )
  end

  test "expires deterministically from an injected virtual clock" do
    {:ok, clock} =
      start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: ~U[2026-03-10 08:00:00Z]})

    verifier_spec = %{
      id: {:virtual_verifier, make_ref()},
      start:
        {Zaik.Home.ActionVerifier, :start_link,
         [
           [
             name: nil,
             timeout_ms: 100,
             retention_ms: 1_000,
             clock: {Zaik.Home.Mirror.Clock, clock}
           ]
         ]}
    }

    {:ok, verifier} = start_supervised(verifier_spec)

    assert {:ok, registered} =
             Zaik.Home.ActionVerifier.register(
               "virtual-expiry",
               "Office blind",
               "cover",
               %{"position" => 10},
               server: verifier
             )

    assert registered.registered_at == "2026-03-10T08:00:00Z"
    assert registered.expires_at == "2026-03-10T08:00:00.100Z"
    assert {:ok, _} = Zaik.Home.ActionVerifier.published("virtual-expiry", server: verifier)

    Zaik.Home.Mirror.Clock.advance(clock, 99)
    Zaik.Home.ActionVerifier.barrier(verifier)

    assert {:ok, %{status: "pending"}} =
             Zaik.Home.ActionVerifier.status("virtual-expiry", server: verifier)

    Zaik.Home.Mirror.Clock.advance(clock, 1)
    Zaik.Home.ActionVerifier.barrier(verifier)

    assert {:ok, %{status: "expired"}} =
             Zaik.Home.ActionVerifier.status("virtual-expiry", server: verifier)
  end

  test "expires an action that never converges", %{verifier: verifier} do
    assert {:ok, _} =
             Zaik.Home.ActionVerifier.register(
               "expired-action",
               "Office blind",
               "cover",
               %{"position" => 10},
               server: verifier,
               timeout_ms: 20
             )

    assert {:ok, _} = Zaik.Home.ActionVerifier.published("expired-action", server: verifier)

    assert %{verified: false, status: "expired", reason: "verification_timeout"} =
             Zaik.Home.ActionVerifier.await("expired-action", 100, server: verifier)
  end
end

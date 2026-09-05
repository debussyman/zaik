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
      %{"state" => "CLOSE", "position" => 1},
      DateTime.utc_now(),
      server: verifier
    )

    assert %{verified: true, observed: %{"position" => 1, "state" => "CLOSE"}} =
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

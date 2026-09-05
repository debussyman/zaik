defmodule Zaik.Home.ActionLedgerTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, ledger} =
      start_supervised({Zaik.Home.ActionLedger, name: nil, db_path: ":memory:"})

    %{ledger: ledger}
  end

  test "returns a stored action result for the same ingress request and semantic args", %{
    ledger: ledger
  } do
    context = %{
      channel: :telegram,
      chat_id: "-100",
      message_id: 42,
      update_id: 900
    }

    args = %{
      "device" => "Office blind",
      "target" => %{"position" => 37, "state" => "STOP"}
    }

    assert {:ok, key} = Zaik.Home.ActionLedger.claim("control_device", args, context, ledger)
    assert is_binary(key)

    assert :ok =
             Zaik.Home.ActionLedger.complete(
               key,
               {:ok, %{status: "accepted", entity_id: "0xoffice"}},
               ledger
             )

    reordered_args = %{
      "target" => %{"state" => "STOP", "position" => 37},
      "device" => "Office blind"
    }

    assert {:duplicate, {:ok, result}} =
             Zaik.Home.ActionLedger.claim(
               "control_device",
               reordered_args,
               context,
               ledger
             )

    assert result["entity_id"] == "0xoffice"
    assert result["duplicate"] == true
    assert result["status"] == "duplicate_suppressed"
  end

  test "persists later correlated verification for plan action results", %{ledger: ledger} do
    context = %{channel: :telegram, chat_id: "-100", message_id: 43}
    args = %{"actions" => [%{"device" => "Office blind"}]}

    assert {:ok, key} = Zaik.Home.ActionLedger.claim("execute_home_plan", args, context, ledger)

    assert :ok =
             Zaik.Home.ActionLedger.complete(
               key,
               {:ok,
                %{
                  status: "accepted",
                  verified: false,
                  actions: [
                    %{
                      result: %{
                        action_id: "child-1",
                        status: "accepted",
                        verified: false
                      }
                    }
                  ]
                }},
               ledger
             )

    Zaik.Home.ActionLedger.mark_verified(
      key,
      "child-1",
      %{verified: true, observed_at: "2026-09-05T08:00:00Z", observed: %{"position" => 0}},
      ledger
    )

    assert {:ok, entry} = Zaik.Home.ActionLedger.lookup(key, ledger)
    assert entry.result["status"] == "verified"
    assert entry.result["verified"] == true
    assert get_in(entry.result, ["actions", Access.at(0), "result", "verified"]) == true

    assert get_in(entry.result, ["actions", Access.at(0), "result", "observed"]) == %{
             "position" => 0
           }
  end

  test "a later verifier report reconciles the persistent ledger", %{ledger: ledger} do
    {:ok, verifier} =
      start_supervised({Zaik.Home.ActionVerifier, name: nil, timeout_ms: 500})

    context = %{channel: :telegram, chat_id: "-100", message_id: 44}
    args = %{"device" => "Office blind", "target" => %{"position" => 37}}
    assert {:ok, key} = Zaik.Home.ActionLedger.claim("control_device", args, context, ledger)

    assert {:ok, _} =
             Zaik.Home.ActionVerifier.register(
               key,
               "Office blind",
               "cover",
               %{"position" => 37},
               server: verifier,
               ledger_key: key,
               ledger: ledger
             )

    assert {:ok, _} = Zaik.Home.ActionVerifier.published(key, server: verifier)

    assert :ok =
             Zaik.Home.ActionLedger.complete(
               key,
               {:ok, %{action_id: key, status: "accepted", verified: false}},
               ledger
             )

    Zaik.Home.ActionVerifier.observe(
      "Office blind",
      %{"position" => 37},
      DateTime.utc_now(),
      server: verifier
    )

    assert %{verified: true} = Zaik.Home.ActionVerifier.await(key, 100, server: verifier)

    assert eventually(fn ->
             with {:ok, entry} <- Zaik.Home.ActionLedger.lookup(key, ledger) do
               entry.result["verified"] == true and entry.result["status"] == "verified"
             end
           end)
  end

  test "persists verifier expiration for retry policy", %{ledger: ledger} do
    {:ok, verifier} =
      start_supervised({Zaik.Home.ActionVerifier, name: nil, timeout_ms: 20})

    context = %{channel: :telegram, chat_id: "-100", message_id: 45}
    args = %{"device" => "Office blind", "target" => %{"position" => 37}}
    assert {:ok, key} = Zaik.Home.ActionLedger.claim("control_device", args, context, ledger)

    assert {:ok, _} =
             Zaik.Home.ActionVerifier.register(
               key,
               "Office blind",
               "cover",
               %{"position" => 37},
               server: verifier,
               ledger_key: key,
               ledger: ledger
             )

    assert {:ok, pending} = Zaik.Home.ActionVerifier.published(key, server: verifier)

    assert :ok =
             Zaik.Home.ActionLedger.complete(
               key,
               {:ok,
                %{
                  action_id: key,
                  device: "Office blind",
                  capability: "cover",
                  target: %{"position" => 37},
                  status: "accepted",
                  verified: false,
                  verification_status: pending.status,
                  verification_expires_at: pending.expires_at,
                  requested_at: pending.published_at
                }},
               ledger
             )

    assert %{status: "expired"} = Zaik.Home.ActionVerifier.await(key, 100, server: verifier)

    assert eventually(fn ->
             with {:ok, entry} <- Zaik.Home.ActionLedger.lookup(key, ledger) do
               entry.result["verification_status"] == "expired" and
                 entry.result["verification_reason"] == "verification_timeout"
             end
           end)
  end

  test "different ingress messages receive different claims", %{ledger: ledger} do
    args = %{"device" => "Office blind", "target" => %{"state" => "CLOSE"}}

    assert {:ok, first} =
             Zaik.Home.ActionLedger.claim(
               "control_device",
               args,
               %{channel: :telegram, chat_id: "-100", message_id: 1},
               ledger
             )

    assert {:ok, second} =
             Zaik.Home.ActionLedger.claim(
               "control_device",
               args,
               %{channel: :telegram, chat_id: "-100", message_id: 2},
               ledger
             )

    refute first == second
  end

  test "requests without a stable ingress identity are explicitly untracked", %{ledger: ledger} do
    assert {:ok, nil} =
             Zaik.Home.ActionLedger.claim(
               "control_device",
               %{"device" => "Office blind"},
               %{},
               ledger
             )
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end

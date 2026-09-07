defmodule Zaik.Home.GetActionStatusTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, ledger} =
      start_supervised({Zaik.Home.ActionLedger, name: nil, db_path: ":memory:"})

    {:ok, verifier} =
      start_supervised({Zaik.Home.ActionVerifier, name: nil, timeout_ms: 500})

    %{ledger: ledger, verifier: verifier}
  end

  test "reads a pending action from the runtime verifier", %{ledger: ledger, verifier: verifier} do
    assert {:ok, _} =
             Zaik.Home.ActionVerifier.register(
               "action-1",
               "Office blind",
               "cover",
               %{"position" => 20},
               server: verifier,
               ledger: ledger
             )

    assert {:ok, _} = Zaik.Home.ActionVerifier.published("action-1", server: verifier)

    assert {:ok, %{source: "verifier", action_id: "action-1", status: status}} =
             Zaik.Home.Tools.GetActionStatus.run(
               %{"action_id" => "action-1"},
               %{action_verifier: verifier, action_ledger: ledger}
             )

    assert status.status == "pending"
  end

  test "falls back to the persistent ledger", %{ledger: ledger, verifier: verifier} do
    context = %{channel: :telegram, chat_id: "-1", message_id: 1}
    args = %{"device" => "Office blind"}
    assert {:ok, key} = Zaik.Home.ActionLedger.claim("control_device", args, context, ledger)
    assert :ok = Zaik.Home.ActionLedger.complete(key, {:ok, %{status: "accepted"}}, ledger)

    assert {:ok, %{source: "ledger", action_id: ^key, status: entry}} =
             Zaik.Home.Tools.GetActionStatus.run(
               %{"action_id" => key},
               %{action_verifier: verifier, action_ledger: ledger}
             )

    assert entry.status == "succeeded"
  end
end

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
end

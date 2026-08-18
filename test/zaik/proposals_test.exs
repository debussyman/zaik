defmodule Zaik.ProposalsTest do
  use ExUnit.Case, async: false

  test "creates, lists, inspects, approves, and rejects proposals" do
    {:ok, proposal} =
      Zaik.Proposals.create(%{
        type: :agent_chat_prompt_tuning,
        title: "Tune prompts",
        body: "Please review a prompt update.",
        action: %{kind: "prompt_patch"},
        created_by: "test"
      })

    assert proposal.status == "pending"
    assert proposal.title == "Tune prompts"

    assert {:ok, pending} = Zaik.Proposals.list(:pending)
    assert Enum.any?(pending, &(&1.id == proposal.id))

    assert {:ok, loaded} = Zaik.Proposals.get(proposal.id)
    assert loaded.action == %{"kind" => "prompt_patch"}

    assert {:ok, approved} = Zaik.Proposals.approve(proposal.id, "user-1")
    assert approved.status == "approved"
    assert approved.decided_by == "user-1"

    assert {:error, :already_decided} = Zaik.Proposals.reject(proposal.id, "user-1")
  end

  test "command processor exposes confirmation workflow" do
    {:ok, proposal} =
      Zaik.Proposals.create(%{
        type: :test,
        title: "Confirm me",
        body: "Needs confirmation.",
        action: %{kind: "noop"}
      })

    assert Zaik.CommandProcessor.process("proposals") =~ proposal.id
    assert Zaik.CommandProcessor.process("proposal #{proposal.id}") =~ "Needs confirmation"

    response = Zaik.CommandProcessor.process("reject #{proposal.id}", %{sender_id: "tester"})
    assert response =~ "Rejected proposal #{proposal.id}"
  end
end

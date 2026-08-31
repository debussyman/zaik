defmodule Zaik.IngressTest do
  use ExUnit.Case, async: false

  defmodule FakeRouter do
    def process(text, context) do
      send(Process.whereis(:zaik_ingress_test), {:router_called, text, context})
      "reply to #{text}"
    end
  end

  setup do
    Process.register(self(), :zaik_ingress_test)

    on_exit(fn ->
      if Process.whereis(:zaik_ingress_test), do: Process.unregister(:zaik_ingress_test)
    end)

    :ok
  end

  test "handles a normalized private message through shared session, memory, and router flow" do
    sender_id = "ingress-user-#{System.unique_integer([:positive])}"

    message = %Zaik.Ingress.Message{
      channel: :test_ingress,
      sender_id: sender_id,
      text: "hello ingress",
      metadata: %{source: "test"}
    }

    assert {:ok, result} = Zaik.Ingress.handle_message(message, router: FakeRouter)
    assert result.response == "reply to hello ingress"
    assert result.session.scope == :test_ingress
    assert result.session.cwd == "test_ingress:user:#{sender_id}"
    assert result.user_entry_id
    assert result.agent_entry_id

    assert_receive {:router_called, "hello ingress", context}
    assert context.channel == :test_ingress
    assert context.sender_id == sender_id
    assert context.sender == sender_id
    assert context.session_id == result.session.id

    assert {:ok, entries} = Zaik.MemoryStore.branch(result.session.id)
    user_entry = Enum.find(entries, &(&1["role"] == "user"))
    agent_entry = Enum.find(entries, &(&1["role"] == "agent"))

    assert user_entry["content"] == "hello ingress"
    assert user_entry["metadata"]["source"] == "test"
    assert user_entry["metadata"]["sender_id"] == sender_id
    assert agent_entry["content"] == "reply to hello ingress"
    assert agent_entry["metadata"]["ingress"] == true
  end

  test "group messages use chat sessions instead of per-sender sessions" do
    chat_id = "-100#{System.unique_integer([:positive])}"

    message = %Zaik.Ingress.Message{
      channel: :telegram,
      sender_id: "user-1",
      chat_id: chat_id,
      chat_type: "group",
      text: "group hello"
    }

    assert {:ok, result} = Zaik.Ingress.handle_message(message, router: FakeRouter)
    assert result.session.cwd == "telegram:chat:#{chat_id}"

    assert_receive {:router_called, "group hello", context}
    assert context.chat_id == chat_id
    assert context.chat_type == "group"
    assert context.sender_id == "user-1"
  end

  test "rejects empty messages and messages without a usable identity" do
    assert {:error, :empty_text} =
             Zaik.Ingress.handle_message(
               %Zaik.Ingress.Message{channel: :telegram, sender_id: "u", text: ""},
               router: FakeRouter
             )

    assert {:error, :missing_identity} =
             Zaik.Ingress.handle_message(%Zaik.Ingress.Message{channel: :telegram, text: "hello"},
               router: FakeRouter
             )
  end
end

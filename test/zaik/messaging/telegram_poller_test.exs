defmodule Zaik.Messaging.TelegramPollerTest do
  use ExUnit.Case, async: true

  test "normalizes Telegram message updates" do
    updates = [
      %{
        "update_id" => 123,
        "message" => %{
          "message_id" => 456,
          "date" => 1_786_000_000,
          "from" => %{"id" => 111, "username" => "ryan", "first_name" => "Ryan"},
          "chat" => %{"id" => 222, "type" => "private"},
          "text" => "How's Lily's room?"
        }
      }
    ]

    assert [message] = Zaik.Messaging.TelegramPoller.normalize_updates(updates)
    assert message.update_id == 123
    assert message.message_id == 456
    assert message.sender_id == "111"
    assert message.sender_username == "ryan"
    assert message.sender_name == "Ryan"
    assert message.chat_id == "222"
    assert message.chat_type == "private"
    assert message.text == "How's Lily's room?"
  end

  test "ignores non-text Telegram updates" do
    updates = [%{"update_id" => 1, "message" => %{"photo" => []}}]

    assert Zaik.Messaging.TelegramPoller.normalize_updates(updates) == []
  end

  test "allows messages from allowlisted users or chats" do
    state = %{
      allowed_user_ids: MapSet.new(["111"]),
      allowed_chat_ids: MapSet.new(["333"])
    }

    assert Zaik.Messaging.TelegramPoller.allowed_message?(state, %{
             sender_id: "111",
             chat_id: "222"
           })

    assert Zaik.Messaging.TelegramPoller.allowed_message?(state, %{
             sender_id: "999",
             chat_id: "333"
           })

    refute Zaik.Messaging.TelegramPoller.allowed_message?(state, %{
             sender_id: "999",
             chat_id: "222"
           })
  end

  test "private messages are always addressed once allowed" do
    message = %{chat_type: "private", text: "How's Lily's room?"}
    state = %{group_trigger: "zaik", bot_username: "zaik_bot"}

    assert {:ok, "How's Lily's room?"} =
             Zaik.Messaging.TelegramPoller.addressed_text(message, state)
  end

  test "group messages require trigger or bot mention" do
    state = %{group_trigger: "zaik", bot_username: "zaik_bot"}

    assert {:ok, "How's Lily's room?"} =
             Zaik.Messaging.TelegramPoller.addressed_text(
               %{chat_type: "group", text: "zaik How's Lily's room?"},
               state
             )

    assert {:ok, "How's Lily's room?"} =
             Zaik.Messaging.TelegramPoller.addressed_text(
               %{chat_type: "supergroup", text: "@zaik_bot, How's Lily's room?"},
               state
             )

    assert :ignore =
             Zaik.Messaging.TelegramPoller.addressed_text(
               %{chat_type: "group", text: "normal conversation"},
               state
             )
  end
end

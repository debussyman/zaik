defmodule Zaik.Messaging.SignalPollerTest do
  use ExUnit.Case, async: true

  test "normalizes signal-cli-rest-api envelope messages" do
    payload = [
      %{
        "envelope" => %{
          "sourceNumber" => "+15551234567",
          "timestamp" => 123,
          "dataMessage" => %{"message" => "health"}
        }
      }
    ]

    assert [message] = Zaik.Messaging.SignalPoller.normalize_messages(payload)
    assert message.sender == "+15551234567"
    assert message.body == "health"
    assert message.timestamp == 123
    assert message.id == "+15551234567:123:health"
  end

  test "normalizes simple message maps" do
    payload = %{"from" => "+15557654321", "body" => "tasks", "id" => "msg-1"}

    assert [%{sender: "+15557654321", body: "tasks", id: "msg-1"}] =
             Zaik.Messaging.SignalPoller.normalize_messages(payload)
  end

  test "normalizes linked-device sync sent messages" do
    payload = %{
      "envelope" => %{
        "sourceNumber" => "+15551234567",
        "timestamp" => 456,
        "syncMessage" => %{
          "sentMessage" => %{
            "destination" => "+15551234567",
            "message" => "system",
            "timestamp" => 456
          }
        }
      }
    }

    assert [%{sender: "+15551234567", body: "system", timestamp: 456}] =
             Zaik.Messaging.SignalPoller.normalize_messages(payload)
  end

  test "decodes signal-cli newline-delimited JSON output" do
    output =
      [
        Jason.encode!(%{
          "envelope" => %{
            "sourceNumber" => "+15551234567",
            "timestamp" => 123,
            "dataMessage" => %{"message" => "health"}
          }
        }),
        "non-json status line"
      ]
      |> Enum.join("\n")

    assert [decoded] = Zaik.Messaging.SignalClient.decode_cli_json_output(output)
    assert get_in(decoded, ["envelope", "sourceNumber"]) == "+15551234567"
  end

  test "allowlist requires exact sender match" do
    allowed = MapSet.new(["+15551234567"])

    assert Zaik.Messaging.SignalPoller.allowed_sender?(allowed, "+15551234567")
    refute Zaik.Messaging.SignalPoller.allowed_sender?(allowed, "+15557654321")
  end

  test "suppresses unknown command responses over Signal" do
    refute Zaik.Messaging.SignalPoller.respond_to_signal_message?(
             "Unknown command.\n\nZaik commands:"
           )

    assert Zaik.Messaging.SignalPoller.respond_to_signal_message?("Zaik is ok.\nQueue: 0")
  end
end

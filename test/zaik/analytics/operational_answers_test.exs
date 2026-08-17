defmodule Zaik.Analytics.OperationalAnswersTest do
  use ExUnit.Case, async: false

  test "answers what we asked today from recorded user messages" do
    now = DateTime.utc_now()

    session = %Zaik.Session{
      id: "ops-answer-#{System.unique_integer([:positive])}",
      path: "/tmp/ops-answer.jsonl",
      scope: :telegram,
      cwd: "telegram:chat:-100",
      created_at: now,
      updated_at: now,
      metadata: %{}
    }

    entry = %{
      "id" => "message-#{System.unique_integer([:positive])}",
      "parentId" => nil,
      "type" => "message",
      "role" => "user",
      "content" => "How's Lily's room?",
      "timestamp" => DateTime.to_iso8601(now),
      "metadata" => %{"channel" => "telegram", "sender_id" => "111", "chat_id" => "-100"}
    }

    assert :ok = Zaik.TelemetryStore.record_session_entry(session, entry)

    assert {:ok, response} =
             Zaik.Analytics.OperationalAnswers.answer("what have we asked you today?")

    assert response =~ "Here is what you've asked me today:"
    assert response =~ "How's Lily's room?"
  end

  test "unknown questions are not claimed" do
    assert :unknown = Zaik.Analytics.OperationalAnswers.answer("why is the sky blue?")
  end
end

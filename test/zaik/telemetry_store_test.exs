defmodule Zaik.TelemetryStoreTest do
  use ExUnit.Case, async: false

  test "projects tasks, sessions, messages, llm calls, and watchdog scans into SQL views" do
    task_id = "task-#{System.unique_integer([:positive])}"
    session_id = "session-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    task =
      Zaik.Task.new(:echo, %{message: "hello"}, id: task_id, session_id: session_id)
      |> Zaik.Task.mark_succeeded(%{ok: true})

    session = %Zaik.Session{
      id: session_id,
      path: "/tmp/#{session_id}.jsonl",
      scope: :telegram,
      cwd: "telegram:user:111",
      created_at: now,
      updated_at: now,
      metadata: %{"sender" => "111"}
    }

    entry = %{
      "id" => "entry-1",
      "parentId" => nil,
      "type" => "message",
      "role" => "user",
      "content" => "How's Lily's room?",
      "timestamp" => DateTime.to_iso8601(now),
      "metadata" => %{"channel" => "telegram", "sender_id" => "111", "chat_id" => "222"}
    }

    assert :ok = Zaik.TelemetryStore.record_task(task, :test)
    assert :ok = Zaik.TelemetryStore.record_session_entry(session, entry)

    assert :ok =
             Zaik.TelemetryStore.record_llm_call(%{purpose: "test", model: "qwen", success: true})

    assert :ok = Zaik.TelemetryStore.record_watchdog_scan(%{requeued_missing_queued_tasks: 0})

    assert :ok =
             Zaik.TelemetryStore.record_agent_chat_run(%{
               id: "agent-chat-test-run",
               prompt: "what have we asked today?",
               context: %{channel: :telegram, chat_id: "222"},
               channel: "telegram",
               chat_id: "222",
               primary_model: "qwen3:4b-instruct",
               fallback_model: "qwen3-coder:30b",
               fallback_used: false,
               final_model: "qwen3:4b-instruct",
               status: :ok,
               answer: "You asked one question.",
               tool_calls: [
                 %{
                   database: :ops,
                   query: "SELECT content FROM zaik_messages",
                   limit: 20,
                   ok: true,
                   row_count: 1
                 }
               ],
               duration_ms: 123
             })

    assert {:ok, %{rows: [%{"id" => ^task_id, "status" => "succeeded"}]}} =
             Zaik.TelemetryStore.query("SELECT id, status FROM zaik_tasks WHERE id = ?", [task_id])

    assert {:ok, %{rows: [%{"id" => ^session_id, "scope" => "telegram"}]}} =
             Zaik.TelemetryStore.query("SELECT id, scope FROM zaik_sessions WHERE id = ?", [
               session_id
             ])

    assert {:ok, %{rows: [%{"content" => "How's Lily's room?", "channel" => "telegram"}]}} =
             Zaik.TelemetryStore.query(
               "SELECT content, channel FROM zaik_messages WHERE session_id = ? AND entry_id = ?",
               [session_id, "entry-1"]
             )

    assert {:ok, %{row_count: count}} =
             Zaik.TelemetryStore.query("SELECT id FROM zaik_llm_calls WHERE purpose = 'test'")

    assert count >= 1

    assert {:ok, %{row_count: count}} =
             Zaik.TelemetryStore.query("SELECT id FROM zaik_watchdog_scans")

    assert count >= 1

    assert {:ok,
            %{
              rows: [
                %{
                  "id" => "agent-chat-test-run",
                  "primary_model" => "qwen3:4b-instruct",
                  "channel" => "telegram",
                  "chat_id" => "222",
                  "fallback_used" => 0,
                  "status" => "ok"
                }
              ]
            }} =
             Zaik.TelemetryStore.query(
               "SELECT id, primary_model, channel, chat_id, fallback_used, status FROM zaik_agent_chat_runs WHERE id = ?",
               ["agent-chat-test-run"]
             )
  end
end

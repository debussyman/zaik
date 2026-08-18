defmodule Zaik.AgentChatTest do
  use ExUnit.Case, async: false

  defmodule FakeClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)

      response =
        if Enum.any?(messages, &tool_result_message?/1) do
          Jason.encode!(%{
            "type" => "final",
            "answer" => "Lily's room has been warm based on the readings."
          })
        else
          Jason.encode!(%{
            "type" => "tool_call",
            "tool" => "sql_query",
            "args" => %{
              "database" => "home",
              "query" =>
                "SELECT recorded_at, temperature_f FROM home_readings WHERE lower(device_name) LIKE '%lily%' ORDER BY recorded_at DESC LIMIT 5",
              "limit" => 5
            }
          })
        end

      {:ok, %{model: "fake", response: response, done: true, raw: %{}}}
    end

    defp tool_result_message?(%{role: "user", content: content}) do
      String.starts_with?(content, "SQL TOOL RESULT") or
        String.starts_with?(String.trim_leading(content), "SQL TOOL RESULT")
    end

    defp tool_result_message?(_message), do: false
  end

  defmodule FakeSQLTool do
    def run(query, opts) do
      send(self(), {:sql_tool_called, query, opts})

      {:ok,
       %{
         columns: ["recorded_at", "temperature_f"],
         rows: [%{"recorded_at" => "2026-08-14T12:00:00Z", "temperature_f" => 78.1}],
         row_count: 1
       }}
    end
  end

  defmodule RawSQLClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)

      response =
        if Enum.any?(messages, &tool_result_message?/1) do
          Jason.encode!(%{"type" => "final", "answer" => "Answered from raw SQL output."})
        else
          "SELECT content FROM zaik_messages WHERE role = 'user' ORDER BY created_at DESC LIMIT 5"
        end

      {:ok, %{model: "raw-sql", response: response, done: true, raw: %{}}}
    end

    defp tool_result_message?(%{role: "user", content: content}) do
      String.starts_with?(String.trim_leading(content), "SQL TOOL RESULT")
    end

    defp tool_result_message?(_message), do: false
  end

  defmodule FallbackClient do
    def chat(_prompt, opts) do
      model = Keyword.fetch!(opts, :model)
      send(self(), {:agent_model_called, model})

      case model do
        "small" ->
          {:error, :invalid_json}

        "big" ->
          {:ok,
           %{
             model: model,
             response: Jason.encode!(%{"type" => "final", "answer" => "fallback answer"}),
             done: true,
             raw: %{}
           }}
      end
    end
  end

  defmodule LowConfidenceClient do
    def chat(_prompt, opts) do
      model = Keyword.fetch!(opts, :model)
      send(self(), {:agent_model_called, model})

      answer =
        case model do
          "small" ->
            "I reached my read-only analysis limit before I could finish. Try asking a narrower question."

          "big" ->
            "fallback answer"
        end

      {:ok,
       %{
         model: model,
         response: Jason.encode!(%{"type" => "final", "answer" => answer}),
         done: true,
         raw: %{}
       }}
    end
  end

  test "loops through a read-only SQL tool call and returns final answer" do
    assert {:ok, answer} =
             Zaik.AgentChat.respond("Was Lily's room warm recently?", %{},
               client: FakeClient,
               sql_tool: FakeSQLTool,
               config: %{enabled: true, max_tool_calls: 3}
             )

    assert answer == "Lily's room has been warm based on the readings."

    assert_received {:sql_tool_called, query, opts}
    assert query =~ "home_readings"
    assert opts[:db] == :home
    assert opts[:limit] == 5

    assert {:ok, %{rows: [row | _]}} =
             Zaik.TelemetryStore.query(
               "SELECT prompt, primary_model, fallback_used, status, answer, tool_calls_json FROM zaik_agent_chat_runs WHERE prompt = ? ORDER BY created_at DESC LIMIT 1",
               ["Was Lily's room warm recently?"]
             )

    assert row["status"] == "ok"
    assert row["answer"] == "Lily's room has been warm based on the readings."
    assert row["fallback_used"] == 0
    assert row["primary_model"]
    assert row["tool_calls_json"] =~ "home_readings"
  end

  test "accepts raw SELECT text from planner as a SQL tool call" do
    assert {:ok, "Answered from raw SQL output."} =
             Zaik.AgentChat.respond("what did we ask recently?", %{},
               client: RawSQLClient,
               sql_tool: FakeSQLTool,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    assert_received {:sql_tool_called, query, opts}
    assert query =~ "zaik_messages"
    assert opts[:db] == :ops
  end

  test "falls back to configured model when primary returns an error" do
    assert {:ok, "fallback answer"} =
             Zaik.AgentChat.respond("hello", %{},
               client: FallbackClient,
               sql_tool: FakeSQLTool,
               config: %{
                 enabled: true,
                 model: "small",
                 fallback_enabled: true,
                 fallback_model: "big",
                 max_tool_calls: 3
               }
             )

    assert_received {:agent_model_called, "small"}
    assert_received {:agent_model_called, "big"}
  end

  test "falls back when primary returns a low-confidence limit answer" do
    assert {:ok, "fallback answer"} =
             Zaik.AgentChat.respond("hello", %{},
               client: LowConfidenceClient,
               sql_tool: FakeSQLTool,
               config: %{
                 enabled: true,
                 model: "small",
                 fallback_enabled: true,
                 fallback_model: "big",
                 max_tool_calls: 3
               }
             )

    assert_received {:agent_model_called, "small"}
    assert_received {:agent_model_called, "big"}
  end
end

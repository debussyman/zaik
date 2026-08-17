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
  end
end

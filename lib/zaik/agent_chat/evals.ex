defmodule Zaik.AgentChat.Evals do
  @moduledoc """
  Lightweight live-model evals for the read-only AgentChat tool loop.

  These evals use the configured Ollama model but a canned SQL tool, so they
  measure model planning/JSON/tool-use behavior without depending on local DB
  contents.
  """

  defmodule CannedSQLTool do
    @moduledoc false

    def run(query, opts) do
      calls = Process.get(:zaik_agent_eval_tool_calls, [])
      Process.put(:zaik_agent_eval_tool_calls, calls ++ [%{query: query, opts: opts}])

      db = Keyword.fetch!(opts, :db)

      with {:ok, _sql} <- Zaik.Analytics.SQLTool.validate(query, db) do
        {:ok, canned_result(db, query)}
      end
    end

    defp canned_result(:ops, query) do
      downcased = String.downcase(query)

      cond do
        String.contains?(downcased, "zaik_messages") ->
          %{
            columns: ["created_at", "channel", "sender_id", "chat_id", "content"],
            rows: [
              %{
                "created_at" => "2026-08-17T15:56:00Z",
                "channel" => "telegram",
                "sender_id" => "111",
                "chat_id" => "-100",
                "content" => "what have we asked you today?"
              },
              %{
                "created_at" => "2026-08-17T16:10:00Z",
                "channel" => "telegram",
                "sender_id" => "222",
                "chat_id" => "-100",
                "content" => "how's Lily's room?"
              }
            ],
            row_count: 2
          }

        String.contains?(downcased, "zaik_tasks") ->
          %{
            columns: ["id", "type", "status", "completed_at", "error_json"],
            rows: [
              %{
                "id" => "task-1",
                "type" => "llm_prompt",
                "status" => "failed",
                "completed_at" => "2026-08-17T14:00:00Z",
                "error_json" => "timeout"
              }
            ],
            row_count: 1
          }

        true ->
          %{columns: [], rows: [], row_count: 0}
      end
    end

    defp canned_result(:home, _query) do
      %{
        columns: [
          "recorded_at",
          "device_name",
          "temperature_f",
          "humidity",
          "illuminance",
          "presence"
        ],
        rows: [
          %{
            "recorded_at" => "2026-08-17T16:00:00Z",
            "device_name" => "Lily's room multi-sensor",
            "temperature_f" => 78.4,
            "humidity" => 56.0,
            "illuminance" => 220,
            "presence" => 1
          },
          %{
            "recorded_at" => "2026-08-17T15:00:00Z",
            "device_name" => "Lily's room multi-sensor",
            "temperature_f" => 77.9,
            "humidity" => 57.0,
            "illuminance" => 180,
            "presence" => 1
          }
        ],
        row_count: 2
      }
    end
  end

  def cases do
    [
      %{
        name: "ops_messages_today_this_chat",
        prompt: "what have we asked you today?",
        context: eval_context(),
        expected_db: :ops,
        expected_query_terms: ["zaik_messages", "role='user'", "chat_id='-100'"],
        forbidden_query_terms: ["sender_id='user'", "channel='main'", "scope='user'"],
        expected_answer_terms: ["asked", "today"]
      },
      %{
        name: "ops_messages_today_me",
        prompt: "what have I asked you today?",
        context: eval_context(),
        expected_db: :ops,
        expected_query_terms: ["zaik_messages", "role='user'", "sender_id='111'"],
        forbidden_query_terms: ["sender_id='user'", "channel='main'", "scope='user'"],
        expected_answer_terms: ["asked", "today"]
      },
      %{
        name: "recent_task_failures",
        prompt: "what tasks failed recently?",
        expected_db: :ops,
        context: eval_context(),
        expected_query_terms: ["zaik_tasks"],
        forbidden_query_terms: [],
        expected_answer_terms: ["failed"]
      },
      %{
        name: "home_lily_warm_recently",
        prompt: "has Lily's room been warm recently?",
        expected_db: :home,
        context: eval_context(),
        expected_query_terms: ["home_readings", "lily"],
        forbidden_query_terms: [],
        expected_answer_terms: ["lily", "warm"]
      }
    ]
  end

  def run(opts \\ []) do
    model = Keyword.get(opts, :model, Zaik.AgentChat.config().model)
    timeout_ms = Keyword.get(opts, :timeout_ms, Zaik.AgentChat.config().timeout_ms)

    results = Enum.map(cases(), &run_case(&1, model, timeout_ms))

    %{
      passed: Enum.count(results, & &1.passed?),
      failed: Enum.count(results, &(not &1.passed?)),
      results: results
    }
  end

  defp run_case(case_def, model, timeout_ms) do
    Process.put(:zaik_agent_eval_tool_calls, [])

    context = Map.get(case_def, :context, %{})

    response =
      Zaik.AgentChat.respond(case_def.prompt, context,
        sql_tool: CannedSQLTool,
        config: %{
          enabled: true,
          model: model,
          timeout_ms: timeout_ms,
          max_tool_calls: 3,
          fallback_enabled: false
        }
      )

    calls = Process.get(:zaik_agent_eval_tool_calls, [])
    checks = checks(case_def, response, calls)

    %{
      name: case_def.name,
      prompt: case_def.prompt,
      response: response,
      planner_prompt: Zaik.AgentChat.Prompts.planner(case_def.prompt, context),
      tool_calls: calls,
      checks: checks,
      passed?: Enum.all?(checks, & &1.passed?)
    }
  after
    Process.delete(:zaik_agent_eval_tool_calls)
  end

  defp checks(case_def, response, calls) do
    [
      check(
        :responded_ok,
        match?({:ok, answer} when is_binary(answer) and answer != "", response)
      ),
      check(:called_tool, length(calls) >= 1),
      check(
        :used_expected_db,
        Enum.any?(calls, &(Keyword.get(&1.opts, :db) == case_def.expected_db))
      ),
      check(:query_mentions_expected_terms, query_terms?(calls, case_def.expected_query_terms)),
      check(
        :query_avoids_forbidden_terms,
        forbidden_terms_absent?(calls, Map.get(case_def, :forbidden_query_terms, []))
      ),
      check(
        :answer_mentions_expected_terms,
        answer_terms?(response, case_def.expected_answer_terms)
      )
    ]
  end

  defp check(name, passed?), do: %{name: name, passed?: passed?}

  defp forbidden_terms_absent?(_calls, []), do: true

  defp forbidden_terms_absent?(calls, terms), do: not query_terms?(calls, terms)

  defp query_terms?(_calls, []), do: true

  defp query_terms?(calls, terms) do
    query_text = calls |> Enum.map(& &1.query) |> Enum.join("\n") |> normalize_sql_text()
    Enum.all?(terms, &String.contains?(query_text, normalize_sql_text(&1)))
  end

  defp normalize_sql_text(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\s+/, "")
  end

  defp answer_terms?({:ok, answer}, terms) do
    answer = String.downcase(answer)
    Enum.all?(terms, &String.contains?(answer, String.downcase(&1)))
  end

  defp answer_terms?(_response, _terms), do: false

  defp eval_context do
    %{
      channel: :telegram,
      sender_id: "111",
      sender: "111",
      chat_id: "-100",
      chat_type: "group",
      session_id: "eval-session"
    }
  end
end

defmodule Zaik.AgentChat.Evals do
  @moduledoc """
  Lightweight live-model evals for the read-only AgentChat tool loop.

  These evals use the configured Ollama model but a canned SQL tool, so they
  measure model planning/JSON/tool-use behavior without depending on local DB
  contents.
  """

  defmodule CannedControlTool do
    @moduledoc false

    def run(tool, args, context) do
      call = %{tool: to_string(tool), args: args}

      case Map.get(context, :eval_pid) || Map.get(context, "eval_pid") do
        pid when is_pid(pid) -> send(pid, {:zaik_agent_eval_control_call, call})
        _ -> :ok
      end

      {:ok,
       %{
         tool: to_string(tool),
         device: Map.get(args, "device") || Map.get(args, :device),
         topic: "eval/no_mqtt_publish",
         payload: Map.get(args, "target") || Map.get(args, :target),
         status: "accepted",
         verified: false,
         requested_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

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

        String.contains?(downcased, "zaik_agent_chat_runs") ->
          %{
            columns: [
              "created_at",
              "prompt",
              "primary_model",
              "fallback_used",
              "final_model",
              "status"
            ],
            rows: [
              %{
                "created_at" => "2026-08-17T17:00:00Z",
                "prompt" => "what have we asked you today?",
                "primary_model" => "qwen3:4b-instruct",
                "fallback_used" => 1,
                "final_model" => "qwen3-coder:30b",
                "status" => "ok"
              }
            ],
            row_count: 1
          }

        true ->
          %{columns: [], rows: [], row_count: 0}
      end
    end

    defp canned_result(:home, query) do
      downcased = String.downcase(query)

      cond do
        String.contains?(downcased, "home_device_presets") ->
          %{
            columns: ["device_name", "preset_name", "capability", "target_json"],
            rows: [
              %{
                "device_name" => "Lily's bedroom right blind",
                "preset_name" => "above AC",
                "capability" => "cover",
                "target_json" => "{\"position\":71}"
              }
            ],
            row_count: 1
          }

        String.contains?(downcased, "home_devices") ->
          %{
            columns: ["friendly_name", "metadata_json", "updated_at"],
            rows: [
              %{
                "friendly_name" => "Lily's room multi-sensor",
                "metadata_json" => "{}",
                "updated_at" => "2026-08-17T16:00:00Z"
              },
              %{
                "friendly_name" => "Lily's bedroom left blind",
                "metadata_json" => "{}",
                "updated_at" => "2026-08-17T16:01:00Z"
              },
              %{
                "friendly_name" => "Lily's bedroom right blind",
                "metadata_json" => "{}",
                "updated_at" => "2026-08-17T16:01:00Z"
              }
            ],
            row_count: 3
          }

        String.contains?(downcased, "temperature_f is not null") ->
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
              }
            ],
            row_count: 1
          }

        true ->
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
                "recorded_at" => "2026-08-17T16:01:00Z",
                "device_name" => "Lily's bedroom right blind",
                "temperature_f" => nil,
                "humidity" => nil,
                "illuminance" => nil,
                "presence" => nil
              },
              %{
                "recorded_at" => "2026-08-17T16:00:00Z",
                "device_name" => "Lily's room multi-sensor",
                "temperature_f" => 78.4,
                "humidity" => 56.0,
                "illuminance" => 220,
                "presence" => 1
              }
            ],
            row_count: 2
          }
      end
    end
  end

  def cases(opts \\ []) do
    include_optional? = Keyword.get(opts, :include_optional, false)

    [
      %{
        name: "ops_messages_today_this_chat",
        prompt: "what have we asked you today?",
        context: eval_context(),
        expected_db: :ops,
        expected_query_terms: ["zaik_messages", "role='user'", "chat_id='-100'"],
        forbidden_query_terms: ["sender_id='user'", "channel='main'", "scope='user'"],
        expected_answer_terms: ["asked"]
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
        name: "agent_chat_fallbacks_recently",
        prompt: "did you fall back to the bigger model recently?",
        expected_db: :ops,
        context: eval_context(),
        expected_query_terms: ["zaik_agent_chat_runs", "fallback_used"],
        forbidden_query_terms: ["zaik_messages", "zaik_tasks"],
        expected_answer_terms: ["back", "model"]
      },
      %{
        name: "home_lily_warm_recently",
        prompt: "has Lily's room been warm recently?",
        expected_db: :home,
        context: eval_context(),
        max_tool_calls: 5,
        expected_query_terms: ["home_readings", "lily"],
        forbidden_query_terms: [],
        expected_answer_terms: ["lily", "warm"]
      },
      %{
        name: "home_lily_current_temperature_ignores_blind_nulls",
        prompt: "What's the temperature in Lily's room?",
        context: eval_context(),
        max_tool_calls: 5,
        expected_registered_tool: "get_home_state",
        expected_registered_arg_terms: ["lily", "temperature"],
        forbidden_query_terms: ["sensor_readings"],
        expected_answer_terms: ["lily", "temperature"]
      },
      %{
        name: "home_lily_temperature_change_30_minutes",
        prompt: "what was Lily's temperature change in the past 30 minutes?",
        expected_db: :home,
        context: eval_context(),
        max_tool_calls: 5,
        expected_query_terms: ["home_readings", "lily", "datetime('now','-30 minutes')"],
        forbidden_query_terms: ["'-3 hours'", "'-1 hour'"],
        expected_answer_terms: ["temperature"]
      },
      %{
        name: "home_lily_temperature_change_3_hours",
        prompt: "what was Lily's temperature change in the past 3 hours?",
        expected_db: :home,
        context: eval_context(),
        max_tool_calls: 5,
        expected_query_terms: ["home_readings", "lily", "datetime('now','-3 hours')"],
        forbidden_query_terms: ["'-30 minutes'", "'-1 hour'"],
        expected_answer_terms: ["temperature"]
      },
      %{
        name: "home_lily_bedtime_with_ac_controls_blinds",
        optional?: true,
        prompt: "Set up Lily's room for bedtime with AC",
        context: eval_context(),
        max_tool_calls: 4,
        expected_control_calls: [
          %{
            tool: "control_blind",
            device_terms: ["lily", "left", "blind"],
            target_terms: ["close"]
          },
          %{
            tool: "control_blind",
            device_terms: ["lily", "right", "blind"],
            target_terms: ["above", "ac"]
          }
        ],
        forbidden_query_terms: ["sensor_readings"],
        expected_answer_terms: ["lily"]
      }
    ]
    |> Enum.reject(&(Map.get(&1, :optional?, false) and not include_optional?))
  end

  def run(opts \\ []) do
    model = Keyword.get(opts, :model, Zaik.AgentChat.config().model)
    timeout_ms = Keyword.get(opts, :timeout_ms, Zaik.AgentChat.config().timeout_ms)

    results = Enum.map(cases(opts), &run_case(&1, model, timeout_ms))

    %{
      passed: Enum.count(results, & &1.passed?),
      failed: Enum.count(results, &(not &1.passed?)),
      results: results
    }
  end

  defp drain_control_calls(calls) do
    receive do
      {:zaik_agent_eval_control_call, call} -> drain_control_calls(calls ++ [call])
    after
      0 -> calls
    end
  end

  defp drain_registered_calls(calls) do
    receive do
      {:zaik_agent_eval_registered_tool_call, call} -> drain_registered_calls(calls ++ [call])
    after
      0 -> calls
    end
  end

  defp run_case(case_def, model, timeout_ms) do
    Process.put(:zaik_agent_eval_tool_calls, [])
    Process.put(:zaik_agent_eval_control_calls, [])
    {:ok, device_store} = GenServer.start_link(Zaik.Home.DeviceStore, [])
    Process.put(:zaik_agent_eval_device_store, device_store)

    Zaik.Home.DeviceStore.upsert_device(
      device_store,
      "Lily's room multi-sensor",
      %{"temperature" => 25.7777778, "humidity" => 56, "illuminance" => 220, "presence" => true},
      %{"area_id" => "lily_bedroom", "source" => "eval"}
    )

    context =
      Map.get(case_def, :context, %{})
      |> Map.put(:eval_pid, self())
      |> Map.put(:device_store, device_store)

    response =
      Zaik.AgentChat.respond(case_def.prompt, context,
        sql_tool: CannedSQLTool,
        control_tool: CannedControlTool,
        config: %{
          enabled: true,
          model: model,
          timeout_ms: timeout_ms,
          max_tool_calls: Map.get(case_def, :max_tool_calls, 3),
          fallback_enabled: false
        }
      )

    sql_calls = Process.get(:zaik_agent_eval_tool_calls, [])
    control_calls = drain_control_calls([])
    registered_calls = drain_registered_calls([])
    checks = checks(case_def, response, sql_calls, control_calls, registered_calls)

    %{
      name: case_def.name,
      prompt: case_def.prompt,
      response: response,
      planner_prompt: Zaik.AgentChat.Prompts.planner(case_def.prompt, context),
      tool_calls: sql_calls,
      sql_calls: sql_calls,
      control_calls: control_calls,
      registered_calls: registered_calls,
      checks: checks,
      passed?: Enum.all?(checks, & &1.passed?)
    }
  after
    Process.delete(:zaik_agent_eval_tool_calls)
    Process.delete(:zaik_agent_eval_control_calls)

    case Process.delete(:zaik_agent_eval_device_store) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: GenServer.stop(pid)
      _ -> :ok
    end
  end

  defp checks(case_def, response, sql_calls, control_calls, registered_calls) do
    base = [
      check(
        :responded_ok,
        match?({:ok, answer} when is_binary(answer) and answer != "", response)
      ),
      check(
        :answer_mentions_expected_terms,
        answer_terms?(response, Map.get(case_def, :expected_answer_terms, []))
      )
    ]

    query_checks =
      if Map.has_key?(case_def, :expected_db) do
        [
          check(:called_sql_tool, length(sql_calls) >= 1),
          check(
            :used_expected_db,
            Enum.any?(sql_calls, &(Keyword.get(&1.opts, :db) == case_def.expected_db))
          ),
          check(
            :query_mentions_expected_terms,
            query_terms?(sql_calls, Map.get(case_def, :expected_query_terms, []))
          )
        ]
      else
        []
      end

    registered_checks =
      if Map.has_key?(case_def, :expected_registered_tool) do
        expected_tool = case_def.expected_registered_tool
        expected_terms = Map.get(case_def, :expected_registered_arg_terms, [])

        [
          check(
            :called_expected_registered_tool,
            Enum.any?(registered_calls, fn call ->
              call.tool == expected_tool and match?({:ok, _result}, call.result)
            end)
          ),
          check(
            :registered_tool_args_match,
            Enum.any?(registered_calls, fn call ->
              call.tool == expected_tool and match?({:ok, _result}, call.result) and
                terms_present?(inspect(call.args), expected_terms)
            end)
          )
        ]
      else
        []
      end

    control_checks =
      if Map.has_key?(case_def, :expected_control_calls) do
        [
          check(:called_control_tool, length(control_calls) >= 1),
          check(
            :control_calls_match_expected,
            control_calls_match?(control_calls, case_def.expected_control_calls)
          )
        ]
      else
        []
      end

    forbidden_checks = [
      check(
        :query_avoids_forbidden_terms,
        forbidden_terms_absent?(sql_calls, Map.get(case_def, :forbidden_query_terms, []))
      )
    ]

    base ++ query_checks ++ registered_checks ++ control_checks ++ forbidden_checks
  end

  defp check(name, passed?), do: %{name: name, passed?: passed?}

  defp control_calls_match?(control_calls, expected_calls) do
    Enum.all?(expected_calls, fn expected ->
      Enum.any?(control_calls, &control_call_matches?(&1, expected))
    end)
  end

  defp control_call_matches?(call, expected) do
    args = call.args || %{}
    device = Map.get(args, "device") || Map.get(args, :device) || ""
    target = Map.get(args, "target") || Map.get(args, :target) || args

    call.tool == expected.tool and
      terms_present?(device, Map.get(expected, :device_terms, [])) and
      target_matches?(args, target, Map.get(expected, :target_terms, []))
  end

  defp target_matches?(args, target, terms) do
    normalized_terms = Enum.map(terms, &normalize_sql_text/1)

    closes_cover? =
      "close" in normalized_terms and
        ((Map.get(target, "position") || Map.get(target, :position)) == 0 or
           String.upcase(to_string(Map.get(target, "state") || Map.get(target, :state))) ==
             "CLOSE")

    closes_cover? or terms_present?(inspect(args), terms)
  end

  defp terms_present?(_text, []), do: true

  defp terms_present?(text, terms) do
    normalized = normalize_sql_text(text)
    Enum.all?(terms, &String.contains?(normalized, normalize_sql_text(&1)))
  end

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

defmodule Zaik.AgentChat.Evals do
  @moduledoc """
  Lightweight live-model evals for the AgentChat tool loop.

  These evals use the configured local model and per-run production-schema
  SQLite fixtures inside an isolated mirror world. They exercise real reads,
  tools, plans, presets, capability validation, verification, and desired-state
  assertions without depending on production databases or publishing MQTT.
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

  defmodule FixtureSQLTool do
    @moduledoc false

    def run(query, opts) do
      calls = Process.get(:zaik_agent_eval_tool_calls, [])
      Process.put(:zaik_agent_eval_tool_calls, calls ++ [%{query: query, opts: opts}])
      Zaik.Analytics.SQLTool.run(query, opts)
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
        expected_answer_terms: [],
        expected_answer_any_terms: ["asked", "what have", "how's"]
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
        name: "home_lily_room_summary",
        prompt: "Give me a summary of Lily's room.",
        context: eval_context(),
        max_tool_calls: 3,
        expected_registered_tool: "get_area_context",
        expected_registered_arg_terms: ["lily", "180", "temperature"],
        forbidden_query_terms: ["home_readings"],
        expected_answer_terms: ["lily", "temperature"]
      },
      %{
        name: "home_lily_warm_recently",
        prompt: "has Lily's room been warm recently?",
        context: eval_context(),
        max_tool_calls: 5,
        expected_registered_tool: "get_home_history",
        expected_registered_arg_terms: ["lily", "temperature"],
        forbidden_query_terms: ["home_readings"],
        expected_answer_terms: ["lily", "warm"]
      },
      %{
        name: "home_lily_warmer_or_cooler",
        prompt: "Is it getting warmer or cooler in Lily's room?",
        context: eval_context(),
        max_tool_calls: 5,
        expected_registered_tool: "get_home_history",
        expected_registered_arg_terms: ["lily", "temperature"],
        forbidden_query_terms: ["home_readings"],
        expected_answer_terms: ["temperature"],
        expected_answer_any_terms: ["warmer", "cooler", "increased", "decreased", "stable"]
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
        name: "home_lily_blind_positions",
        prompt: "What position are Lily's blinds in?",
        context: eval_context(),
        max_tool_calls: 5,
        expected_registered_tool: "get_home_state",
        expected_registered_arg_terms: ["lily", "cover"],
        forbidden_query_terms: ["home_readings"],
        expected_answer_terms: ["left", "right"],
        expected_answer_any_terms: ["0", "open"]
      },
      %{
        name: "home_lily_temperature_change_30_minutes",
        prompt: "what was Lily's temperature change in the past 30 minutes?",
        context: eval_context(),
        max_tool_calls: 5,
        expected_registered_tool: "get_home_history",
        expected_registered_arg_terms: ["lily", "temperature", "30"],
        forbidden_query_terms: ["home_readings", "180"],
        expected_answer_terms: ["temperature"]
      },
      %{
        name: "home_lily_temperature_change_3_hours",
        prompt: "what was Lily's temperature change in the past 3 hours?",
        context: eval_context(),
        max_tool_calls: 5,
        expected_registered_tool: "get_home_history",
        expected_registered_arg_terms: ["lily", "temperature", "180"],
        forbidden_query_terms: ["home_readings", "30"],
        expected_answer_terms: ["temperature"]
      },
      %{
        name: "home_lily_bedtime_with_ac_controls_blinds",
        optional?: true,
        prompt: "Set up Lily's room for bedtime with AC",
        context: eval_context(),
        max_tool_calls: 4,
        expected_registered_tool: "execute_home_plan",
        expected_registered_arg_terms: ["lily", "left", "right", "above", "ac"],
        expected_control_calls: [
          %{
            tool: "execute_home_plan",
            device_terms: ["lily", "left", "blind"],
            target_terms: ["close"]
          },
          %{
            tool: "execute_home_plan",
            device_terms: ["lily", "right", "blind"],
            target_terms: ["position", "71"]
          }
        ],
        forbidden_query_terms: ["sensor_readings"],
        expected_answer_terms: ["lily"],
        expected_mirror_state?: true
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
    {:ok, mirror} = Zaik.Home.Mirror.start(eval_mirror_scenario())
    Process.put(:zaik_agent_eval_mirror, mirror)

    context =
      mirror
      |> Zaik.Home.Mirror.context(Map.get(case_def, :context, %{}))
      |> Map.put(:eval_pid, self())

    response =
      Zaik.AgentChat.respond(case_def.prompt, context,
        sql_tool: FixtureSQLTool,
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
    mirror_report = Zaik.Home.Mirror.Assertions.evaluate(mirror)

    control_calls =
      drain_control_calls([]) ++ mirror_control_calls(mirror_report.actions, case_def)

    registered_calls = drain_registered_calls([])

    checks =
      checks(case_def, response, sql_calls, control_calls, registered_calls) ++
        mirror_checks(case_def, mirror_report)

    %{
      name: case_def.name,
      prompt: case_def.prompt,
      response: response,
      planner_prompt: Zaik.AgentChat.Prompts.planner(case_def.prompt, context),
      tool_calls: sql_calls,
      sql_calls: sql_calls,
      control_calls: control_calls,
      registered_calls: registered_calls,
      mirror_report: mirror_report,
      checks: checks,
      passed?: Enum.all?(checks, & &1.passed?)
    }
  after
    Process.delete(:zaik_agent_eval_tool_calls)
    Process.delete(:zaik_agent_eval_control_calls)

    case Process.delete(:zaik_agent_eval_mirror) do
      %Zaik.Home.Mirror{} = mirror -> Zaik.Home.Mirror.stop(mirror)
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

    answer_any_checks =
      case Map.get(case_def, :expected_answer_any_terms, []) do
        [] -> []
        terms -> [check(:answer_mentions_fixture_content, answer_any_term?(response, terms))]
      end

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

    base ++
      answer_any_checks ++ query_checks ++ registered_checks ++ control_checks ++ forbidden_checks
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

  defp answer_any_term?({:ok, answer}, terms) do
    answer = String.downcase(answer)
    Enum.any?(terms, &String.contains?(answer, String.downcase(&1)))
  end

  defp answer_any_term?(_response, _terms), do: false

  defp mirror_control_calls(actions, case_def) do
    tool = Map.get(case_def, :expected_registered_tool, "mirror_action")

    Enum.map(actions, fn action ->
      %{
        tool: tool,
        args: %{"device" => action.device, "target" => action.target}
      }
    end)
  end

  defp mirror_checks(case_def, report) do
    if Map.get(case_def, :expected_mirror_state?, false) do
      [
        check(:mirror_reached_desired_state, report.passed?),
        check(:mirror_used_only_expected_side_effects, report.side_effect_count == 2)
      ]
    else
      []
    end
  end

  defp eval_mirror_scenario do
    Zaik.Home.Mirror.Scenarios.lily_with_history_and_telemetry(
      id: "agent_eval_lily_bedtime",
      now: DateTime.utc_now()
    )
  end

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

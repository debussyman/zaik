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

  defmodule SQLResultDriftClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)

      response =
        cond do
          Enum.any?(messages, &original_question?/1) ->
            %{"type" => "final", "answer" => "You asked how Lily's room is."}

          Enum.any?(messages, &sql_result?/1) ->
            %{
              "type" => "tool_call",
              "tool" => "get_home_state",
              "args" => %{"query" => "lily", "capability" => "temperature"}
            }

          true ->
            %{
              "type" => "tool_call",
              "tool" => "sql_query",
              "args" => %{
                "database" => "ops",
                "query" => "SELECT content FROM zaik_messages LIMIT 10"
              }
            }
        end

      {:ok, %{model: "sql-drift", response: Jason.encode!(response), done: true, raw: %{}}}
    end

    defp original_question?(%{content: content}) when is_binary(content),
      do: String.starts_with?(content, "Original user question:")

    defp original_question?(_message), do: false

    defp sql_result?(%{content: content}) when is_binary(content),
      do: String.starts_with?(String.trim_leading(content), "SQL TOOL RESULT")

    defp sql_result?(_message), do: false
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

  defmodule HomeControlCorrectionClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)

      response =
        cond do
          Enum.any?(messages, &home_tool_result_message?/1) ->
            Jason.encode!(%{"type" => "final", "answer" => "Done after tool result."})

          Enum.any?(messages, &home_control_correction?/1) ->
            Jason.encode!(%{
              "type" => "tool_call",
              "tool" => "control_blind",
              "args" => %{
                "device" => "Lily's bedroom left blind",
                "target" => %{"state" => "CLOSE"}
              }
            })

          true ->
            Jason.encode!(%{"type" => "final", "answer" => "Done. Lily's room is ready."})
        end

      {:ok, %{model: "home-control-correction", response: response, done: true, raw: %{}}}
    end

    defp home_control_correction?(%{content: content}) when is_binary(content),
      do: String.contains?(content, "HOME CONTROL CORRECTION")

    defp home_control_correction?(_message), do: false

    defp home_tool_result_message?(%{role: "user", content: content}) do
      String.starts_with?(String.trim_leading(content), "HOME TOOL RESULT")
    end

    defp home_tool_result_message?(_message), do: false
  end

  defmodule InvalidSkillToolClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)

      response =
        cond do
          Enum.any?(messages, &home_tool_result_message?/1) ->
            Jason.encode!(%{"type" => "final", "answer" => "The command was accepted."})

          Enum.any?(messages, &tool_correction?/1) ->
            Jason.encode!(%{
              "type" => "tool_call",
              "tool" => "control_blind",
              "args" => %{
                "device" => "Lily's bedroom left blind",
                "target" => %{"state" => "CLOSE"}
              }
            })

          true ->
            Jason.encode!(%{"type" => "tool_call", "tool" => "lily_bedtime_with_ac"})
        end

      {:ok, %{model: "skill-tool-repair", response: response, done: true, raw: %{}}}
    end

    defp tool_correction?(%{content: content}) when is_binary(content),
      do: String.contains?(content, "HOME CONTROL TOOL CORRECTION")

    defp tool_correction?(_message), do: false

    defp home_tool_result_message?(%{role: "user", content: content}) when is_binary(content),
      do: String.starts_with?(String.trim_leading(content), "HOME TOOL RESULT")

    defp home_tool_result_message?(_message), do: false
  end

  defmodule HomeControlClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)
      home_tool_results = Enum.count(messages, &home_tool_result_message?/1)

      response =
        case home_tool_results do
          0 ->
            Jason.encode!(%{
              "type" => "tool_call",
              "tool" => "control_blind",
              "args" => %{
                "device" => "Lily's bedroom left blind",
                "target" => %{"state" => "CLOSE"}
              }
            })

          1 ->
            Jason.encode!(%{
              "type" => "tool_call",
              "tool" => "control_blind",
              "args" => %{
                "device" => "Lily's bedroom right blind",
                "target" => %{"preset" => "above AC"}
              }
            })

          _ ->
            Jason.encode!(%{
              "type" => "final",
              "answer" => "Done. I closed Lily's left blind and set the right blind above the AC."
            })
        end

      {:ok, %{model: "home-control", response: response, done: true, raw: %{}}}
    end

    defp home_tool_result_message?(%{role: "user", content: content}) do
      String.starts_with?(String.trim_leading(content), "HOME TOOL RESULT")
    end

    defp home_tool_result_message?(_message), do: false
  end

  defmodule FakeControlTool do
    def run(tool, args, context) do
      send(Map.fetch!(context, :test_pid), {:control_tool_called, tool, args})

      {:ok,
       %{
         tool: tool,
         device: args["device"],
         topic: "zigbee2mqtt/#{args["device"]}/set",
         payload: args["target"],
         status: "verified",
         verified: true,
         requested_at: "2026-09-04T19:00:00Z"
       }}
    end
  end

  defmodule UnverifiedControlTool do
    def run(tool, args, context) do
      send(Map.fetch!(context, :test_pid), {:unverified_control_called, tool, args})

      {:ok,
       %{
         tool: tool,
         action_id: "test-action-id",
         device: args["device"],
         status: "accepted",
         verified: false,
         payload: args["target"]
       }}
    end
  end

  defmodule FailingControlTool do
    def run(tool, args, context) do
      send(Map.fetch!(context, :test_pid), {:failing_control_called, tool, args})
      {:error, :transport_failed}
    end
  end

  defmodule MalformedFinalClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)

      response =
        if Enum.any?(messages, &tool_result_message?/1) do
          Jason.encode!(%{
            "type" => "tool_call",
            "tool" => "sql_query",
            "args" => %{"query" => "You recently asked about Lily's room."}
          })
        else
          Jason.encode!(%{
            "type" => "tool_call",
            "tool" => "sql_query",
            "args" => %{
              "database" => "ops",
              "query" => "SELECT content FROM zaik_messages WHERE role = 'user' LIMIT 5",
              "limit" => 5
            }
          })
        end

      {:ok, %{model: "malformed-final", response: response, done: true, raw: %{}}}
    end

    defp tool_result_message?(%{role: "user", content: content}) do
      String.starts_with?(String.trim_leading(content), "SQL TOOL RESULT")
    end

    defp tool_result_message?(_message), do: false
  end

  defmodule MalformedJsonishFinalClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)

      response =
        if Enum.any?(messages, &tool_result_message?/1) do
          ~s({"type":"final","answer":"Today, you asked about "Lily's room" in chat."})
        else
          Jason.encode!(%{
            "type" => "tool_call",
            "tool" => "sql_query",
            "args" => %{
              "database" => "ops",
              "query" => "SELECT content FROM zaik_messages WHERE role = 'user' LIMIT 5",
              "limit" => 5
            }
          })
        end

      {:ok, %{model: "jsonish-final", response: response, done: true, raw: %{}}}
    end

    defp tool_result_message?(%{role: "user", content: content}) do
      String.starts_with?(String.trim_leading(content), "SQL TOOL RESULT")
    end

    defp tool_result_message?(_message), do: false
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

  defmodule MultiQueryClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)
      tool_result_count = Enum.count(messages, &tool_result_message?/1)

      response =
        case tool_result_count do
          0 ->
            tool_call(
              "SELECT recorded_at, temperature_f, humidity, illuminance, presence FROM home_readings WHERE lower(device_name) LIKE '%lily%' ORDER BY recorded_at DESC LIMIT 1",
              1
            )

          1 ->
            tool_call(
              "SELECT recorded_at, temperature_f FROM home_readings WHERE lower(device_name) LIKE '%lily%' AND recorded_at >= datetime('now', '-3 hours') ORDER BY recorded_at DESC LIMIT 20",
              20
            )

          _ ->
            Jason.encode!(%{
              "type" => "final",
              "answer" => "Lily's room is warm with a recent trend."
            })
        end

      {:ok, %{model: "multi-query", response: response, done: true, raw: %{}}}
    end

    defp tool_call(query, limit) do
      Jason.encode!(%{
        "type" => "tool_call",
        "tool" => "sql_query",
        "args" => %{"database" => "home", "query" => query, "limit" => limit}
      })
    end

    defp tool_result_message?(%{role: "user", content: content}) do
      String.starts_with?(String.trim_leading(content), "SQL TOOL RESULT")
    end

    defp tool_result_message?(_message), do: false
  end

  defmodule FinalRetryClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)

      response =
        if Enum.any?(messages, &final_correction_message?/1) do
          Jason.encode!(%{"type" => "final", "answer" => "Lily's room is warm and occupied."})
        else
          Jason.encode!(%{
            "type" => "tool_call",
            "tool" => "sql_query",
            "args" => %{
              "database" => "home",
              "query" =>
                "SELECT recorded_at, temperature_f FROM home_readings ORDER BY recorded_at DESC LIMIT 20"
            }
          })
        end

      {:ok, %{model: "final-retry", response: response, done: true, raw: %{}}}
    end

    defp final_correction_message?(%{content: content}) when is_binary(content),
      do: String.contains?(content, "FINAL ANSWER CORRECTION")

    defp final_correction_message?(_message), do: false
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

  defmodule ContradictoryClient do
    def chat(_prompt, opts) do
      model = Keyword.fetch!(opts, :model)
      messages = Keyword.fetch!(opts, :messages)
      send(self(), {:agent_model_called, model})

      response =
        cond do
          model == "big" ->
            Jason.encode!(%{"type" => "final", "answer" => "fallback answer"})

          Enum.any?(messages, &tool_result_message?/1) ->
            Jason.encode!(%{"type" => "final", "answer" => "No matching rows were found."})

          true ->
            Jason.encode!(%{
              "type" => "tool_call",
              "tool" => "sql_query",
              "args" => %{
                "database" => "ops",
                "query" => "SELECT content FROM zaik_messages LIMIT 5"
              }
            })
        end

      {:ok, %{model: model, response: response, done: true, raw: %{}}}
    end

    defp tool_result_message?(%{role: "user", content: content}) do
      String.starts_with?(String.trim_leading(content), "SQL TOOL RESULT")
    end

    defp tool_result_message?(_message), do: false
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

  defmodule RepairClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)

      response =
        cond do
          Enum.any?(messages, &tool_result_message?/1) ->
            Jason.encode!(%{"type" => "final", "answer" => "The main bedroom is 80.6°F."})

          Enum.any?(messages, &planner_repair_message?/1) ->
            Jason.encode!(%{
              "type" => "tool_call",
              "tool" => "sql_query",
              "args" => %{
                "database" => "home",
                "query" =>
                  "SELECT recorded_at, temperature_f FROM home_readings WHERE lower(device_name) LIKE '%main bedroom%' ORDER BY recorded_at DESC LIMIT 1",
                "limit" => 1
              }
            })

          true ->
            "I don't know what it is like in the main bedroom."
        end

      {:ok, %{model: "repair", response: response, done: true, raw: %{}}}
    end

    defp planner_repair_message?(%{content: content}) when is_binary(content),
      do: String.contains?(content, "PLANNER JSON CORRECTION")

    defp planner_repair_message?(_message), do: false

    defp tool_result_message?(%{role: "user", content: content}) do
      String.starts_with?(String.trim_leading(content), "SQL TOOL RESULT")
    end

    defp tool_result_message?(_message), do: false
  end

  defmodule StatusMessageClient do
    def chat(_prompt, _opts) do
      {:ok,
       %{
         model: "status-message",
         response:
           Jason.encode!(%{
             "status" => "success",
             "message" => "The main bedroom is currently at 80.6°F."
           }),
         done: true,
         raw: %{}
       }}
    end
  end

  defmodule RawToolResultEchoClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)

      response =
        cond do
          Enum.any?(messages, &final_answer_mode?/1) ->
            Jason.encode!(%{"type" => "final", "answer" => "The main bedroom is 80.6°F."})

          Enum.any?(messages, &tool_result_message?/1) ->
            Jason.encode!(%{
              "columns" => ["device_name", "temperature_f"],
              "rows" => [%{"device_name" => "Main bedroom multi-sensor", "temperature_f" => 80.6}],
              "row_count" => 1,
              "error" => nil
            })

          true ->
            Jason.encode!(%{
              "type" => "tool_call",
              "tool" => "sql_query",
              "args" => %{
                "database" => "home",
                "query" =>
                  "SELECT device_name, temperature_f FROM home_readings WHERE lower(device_name) LIKE '%main bedroom%' ORDER BY recorded_at DESC LIMIT 1",
                "limit" => 1
              }
            })
        end

      {:ok, %{model: "raw-tool-result-echo", response: response, done: true, raw: %{}}}
    end

    defp final_answer_mode?(%{content: content}) when is_binary(content),
      do: String.contains?(content, "FINAL ANSWER MODE")

    defp final_answer_mode?(_message), do: false

    defp tool_result_message?(%{role: "user", content: content}) do
      String.starts_with?(String.trim_leading(content), "SQL TOOL RESULT")
    end

    defp tool_result_message?(_message), do: false
  end

  defmodule DuplicateControlClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)
      results = Enum.count(messages, &home_tool_result?/1)

      response =
        if results < 2 do
          Jason.encode!(%{
            "type" => "tool_call",
            "tool" => "control_blind",
            "args" => %{"device" => "Office blind", "target" => %{"state" => "CLOSE"}}
          })
        else
          Jason.encode!(%{"type" => "final", "answer" => "The command was accepted."})
        end

      {:ok, %{model: "duplicate", response: response, done: true, raw: %{}}}
    end

    defp home_tool_result?(%{content: content}) when is_binary(content),
      do: String.starts_with?(String.trim_leading(content), "HOME TOOL RESULT")

    defp home_tool_result?(_message), do: false
  end

  defmodule ActionFallbackClient do
    def chat(_prompt, opts) do
      model = Keyword.fetch!(opts, :model)
      messages = Keyword.fetch!(opts, :messages)
      send(self(), {:agent_model_called, model})

      response =
        if Enum.any?(messages, &home_tool_result?/1) do
          Jason.encode!(%{
            "type" => "final",
            "answer" => "I reached my read-only analysis limit before I could finish."
          })
        else
          Jason.encode!(%{
            "type" => "tool_call",
            "tool" => "control_blind",
            "args" => %{"device" => "Office blind", "target" => %{"state" => "CLOSE"}}
          })
        end

      {:ok, %{model: model, response: response, done: true, raw: %{}}}
    end

    defp home_tool_result?(%{content: content}) when is_binary(content),
      do: String.starts_with?(String.trim_leading(content), "HOME TOOL RESULT")

    defp home_tool_result?(_message), do: false
  end

  defmodule TypedHomeStateClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)

      response =
        if Enum.any?(messages, &typed_tool_result?/1) do
          Jason.encode!(%{"type" => "final", "answer" => "The nursery is 77°F."})
        else
          Jason.encode!(%{
            "type" => "tool_call",
            "tool" => "get_home_state",
            "args" => %{"query" => "nursery", "capability" => "temperature"}
          })
        end

      {:ok, %{model: "typed-home", response: response, done: true, raw: %{}}}
    end

    defp typed_tool_result?(%{content: content}) when is_binary(content),
      do: String.starts_with?(String.trim_leading(content), "TOOL RESULT")

    defp typed_tool_result?(_message), do: false
  end

  defmodule PlanCoverExecutor do
    @behaviour Zaik.Home.Executor

    def capability, do: "cover"
    def prepare(_entity, target, _context), do: {:ok, target}

    def execute(entity, target, context) do
      send(context.test_pid, {:plan_action_executed, entity.id, target})
      {:ok, %{status: "accepted", verified: false, entity_id: entity.id, target: target}}
    end
  end

  defmodule HomePlanClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)

      response =
        if Enum.any?(messages, &tool_result?/1) do
          Jason.encode!(%{"type" => "final", "answer" => "Both commands were accepted."})
        else
          Jason.encode!(%{
            "type" => "tool_call",
            "tool" => "execute_home_plan",
            "args" => %{
              "goal" => "bedtime",
              "actions" => [
                %{
                  "device" => "Left blind",
                  "capability" => "cover",
                  "target" => %{"state" => "CLOSE"}
                },
                %{
                  "device" => "Right blind",
                  "capability" => "cover",
                  "target" => %{"position" => 71}
                }
              ]
            }
          })
        end

      {:ok, %{model: "home-plan", response: response, done: true, raw: %{}}}
    end

    defp tool_result?(%{content: content}) when is_binary(content),
      do: String.starts_with?(String.trim_leading(content), "TOOL RESULT")

    defp tool_result?(_message), do: false
  end

  defmodule HistoricalToolCorrectionClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)

      response =
        cond do
          Enum.any?(messages, &sql_tool_result?/1) ->
            Jason.encode!(%{"type" => "final", "answer" => "The temperature changed by 1°F."})

          Enum.any?(messages, &tool_selection_correction?/1) ->
            Jason.encode!(%{
              "type" => "tool_call",
              "tool" => "sql_query",
              "args" => %{
                "database" => "home",
                "query" =>
                  "SELECT recorded_at, temperature_f FROM home_readings WHERE lower(room) LIKE '%lily%' AND temperature_f IS NOT NULL AND recorded_at >= datetime('now', '-30 minutes')",
                "limit" => 20
              }
            })

          true ->
            Jason.encode!(%{
              "type" => "tool_call",
              "tool" => "get_home_state",
              "args" => %{"query" => "lily", "capability" => "temperature"}
            })
        end

      {:ok, %{model: "tool-correction", response: response, done: true, raw: %{}}}
    end

    defp tool_selection_correction?(%{content: content}) when is_binary(content),
      do: String.contains?(content, "TOOL SELECTION CORRECTION")

    defp tool_selection_correction?(_message), do: false

    defp sql_tool_result?(%{content: content}) when is_binary(content),
      do: String.starts_with?(String.trim_leading(content), "SQL TOOL RESULT")

    defp sql_tool_result?(_message), do: false
  end

  defmodule SQLDoesNotConfirmControlClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)

      response =
        cond do
          Enum.any?(messages, &home_tool_result?/1) ->
            Jason.encode!(%{"type" => "final", "answer" => "The command was accepted."})

          Enum.any?(messages, &control_correction?/1) ->
            Jason.encode!(%{
              "type" => "tool_call",
              "tool" => "control_blind",
              "args" => %{"device" => "Office blind", "target" => %{"state" => "CLOSE"}}
            })

          Enum.any?(messages, &sql_tool_result?/1) ->
            Jason.encode!(%{"type" => "final", "answer" => "Done. The blind is closed."})

          true ->
            Jason.encode!(%{
              "type" => "tool_call",
              "tool" => "sql_query",
              "args" => %{"database" => "home", "query" => "SELECT 1", "limit" => 1}
            })
        end

      {:ok, %{model: "typed-success", response: response, done: true, raw: %{}}}
    end

    defp home_tool_result?(%{content: content}) when is_binary(content),
      do: String.starts_with?(String.trim_leading(content), "HOME TOOL RESULT")

    defp home_tool_result?(_message), do: false

    defp sql_tool_result?(%{content: content}) when is_binary(content),
      do: String.starts_with?(String.trim_leading(content), "SQL TOOL RESULT")

    defp sql_tool_result?(_message), do: false

    defp control_correction?(%{content: content}) when is_binary(content),
      do: String.contains?(content, "HOME CONTROL CORRECTION")

    defp control_correction?(_message), do: false
  end

  test "loops through a read-only SQL tool call and returns final answer" do
    assert {:ok, answer} =
             Zaik.AgentChat.respond(
               "Was Lily's room warm recently?",
               %{sql_tool_opts: [home_db_path: "/tmp/mirror-home.db"]},
               client: FakeClient,
               sql_tool: FakeSQLTool,
               config: %{enabled: true, max_tool_calls: 3}
             )

    assert answer == "Lily's room has been warm based on the readings."

    assert_received {:sql_tool_called, query, opts}
    assert query =~ "home_readings"
    assert opts[:db] == :home
    assert opts[:limit] == 5
    assert opts[:home_db_path] == "/tmp/mirror-home.db"

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

  test "writes traces to an injected telemetry store instead of production telemetry" do
    {:ok, telemetry} =
      start_supervised({Zaik.TelemetryStore, name: nil, db_path: ":memory:"})

    prompt = "Was Lily's room warm recently? isolated-#{System.unique_integer([:positive])}"

    assert {:ok, _answer} =
             Zaik.AgentChat.respond(prompt, %{telemetry_store: telemetry},
               client: FakeClient,
               sql_tool: FakeSQLTool,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    assert {:ok, %{row_count: 1}} =
             Zaik.TelemetryStore.query(
               telemetry,
               "SELECT id FROM zaik_agent_chat_runs WHERE prompt = ?",
               [prompt],
               []
             )

    assert {:ok, %{row_count: 0}} =
             Zaik.TelemetryStore.query(
               "SELECT id FROM zaik_agent_chat_runs WHERE prompt = ?",
               [prompt]
             )
  end

  test "finalizes from successful SQL instead of following stored-message tool drift" do
    assert {:ok, "You asked how Lily's room is."} =
             Zaik.AgentChat.respond(
               "What have we asked today?",
               %{eval_pid: self()},
               client: SQLResultDriftClient,
               sql_tool: FakeSQLTool,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    refute_received {:zaik_agent_eval_registered_tool_call, %{tool: "get_home_state"}}
  end

  test "does not accept home-control done claims before a tool succeeds" do
    assert {:ok, "Done after tool result."} =
             Zaik.AgentChat.respond("Set up Lily's room for bedtime with AC", %{test_pid: self()},
               client: HomeControlCorrectionClient,
               sql_tool: FakeSQLTool,
               control_tool: FakeControlTool,
               prompt_domain: :home_control,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    assert_received {:control_tool_called, "control_blind",
                     %{
                       "device" => "Lily's bedroom left blind",
                       "target" => %{"state" => "CLOSE"}
                     }}
  end

  test "repairs a skill name emitted as if it were a home-control tool" do
    assert {:ok, "The command was accepted."} =
             Zaik.AgentChat.respond(
               "Set up Lily's room for bedtime with AC",
               %{test_pid: self()},
               client: InvalidSkillToolClient,
               control_tool: FakeControlTool,
               prompt_domain: :home_control,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    assert_received {:control_tool_called, "control_blind", _args}
  end

  test "does not describe an accepted command as verified physical completion" do
    assert {:ok, answer} =
             Zaik.AgentChat.respond(
               "Set up Lily's room for bedtime with AC",
               %{test_pid: self()},
               client: HomeControlCorrectionClient,
               control_tool: UnverifiedControlTool,
               prompt_domain: :home_control,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    assert answer =~ "commands were accepted"
    assert answer =~ "haven't verified"
    assert answer =~ "Action ID: test-action-id"
    refute answer =~ "Done"
    assert_received {:unverified_control_called, "control_blind", _args}
  end

  test "loops through validated home-control tool calls and returns final answer" do
    assert {:ok, answer} =
             Zaik.AgentChat.respond("Set up Lily's room for bedtime with AC", %{test_pid: self()},
               client: HomeControlClient,
               sql_tool: FakeSQLTool,
               control_tool: FakeControlTool,
               prompt_domain: :home_control,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    assert answer == "Done. I closed Lily's left blind and set the right blind above the AC."

    assert_received {:control_tool_called, "control_blind",
                     %{
                       "device" => "Lily's bedroom left blind",
                       "target" => %{"state" => "CLOSE"}
                     }}

    assert_received {:control_tool_called, "control_blind",
                     %{
                       "device" => "Lily's bedroom right blind",
                       "target" => %{"preset" => "above AC"}
                     }}
  end

  test "accepts prose answer accidentally returned in final tool-call query field" do
    assert {:ok, "You recently asked about Lily's room."} =
             Zaik.AgentChat.respond("what did we ask recently?", %{},
               client: MalformedFinalClient,
               sql_tool: FakeSQLTool,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    assert_received {:sql_tool_called, query, opts}
    assert query =~ "zaik_messages"
    assert opts[:db] == :ops
  end

  test "allows another useful SQL query after a successful SQL result" do
    assert {:ok, "Lily's room is warm with a recent trend."} =
             Zaik.AgentChat.respond("how's Lily's room", %{},
               client: MultiQueryClient,
               sql_tool: FakeSQLTool,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    assert_received {:sql_tool_called, first_query, first_opts}
    assert first_query =~ "ORDER BY recorded_at DESC LIMIT 1"
    assert first_opts[:db] == :home

    assert_received {:sql_tool_called, second_query, second_opts}
    assert second_query =~ "datetime('now', '-3 hours')"
    assert second_opts[:db] == :home
  end

  test "forces final answer when model keeps requesting SQL after budget is exhausted" do
    assert {:ok, "Lily's room is warm and occupied."} =
             Zaik.AgentChat.respond("how's Lily's room", %{},
               client: FinalRetryClient,
               sql_tool: FakeSQLTool,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 2}
             )

    assert_received {:sql_tool_called, query, opts}
    assert query =~ "home_readings"
    assert opts[:db] == :home
  end

  test "salvages JSON-looking final answers with unescaped inner quotes" do
    assert {:ok, answer} =
             Zaik.AgentChat.respond("what did we ask recently?", %{},
               client: MalformedJsonishFinalClient,
               sql_tool: FakeSQLTool,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    assert answer =~ "Lily's room"
    assert_received {:sql_tool_called, query, opts}
    assert query =~ "zaik_messages"
    assert opts[:db] == :ops
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

  test "repairs a non-JSON planner response once before failing" do
    assert {:ok, "The main bedroom is 80.6°F."} =
             Zaik.AgentChat.respond("what is it like in the main bedroom?", %{},
               client: RepairClient,
               sql_tool: FakeSQLTool,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    assert_received {:sql_tool_called, query, opts}
    assert query =~ "home_readings"
    assert query =~ "main bedroom"
    assert opts[:db] == :home
  end

  test "accepts status/message JSON as a final answer" do
    assert {:ok, "The main bedroom is currently at 80.6°F."} =
             Zaik.AgentChat.respond("hello", %{},
               client: StatusMessageClient,
               sql_tool: FakeSQLTool,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )
  end

  test "forces final answer when model echoes raw SQL result JSON" do
    assert {:ok, "The main bedroom is 80.6°F."} =
             Zaik.AgentChat.respond("what is it like in the main bedroom?", %{},
               client: RawToolResultEchoClient,
               sql_tool: FakeSQLTool,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    assert_received {:sql_tool_called, query, opts}
    assert query =~ "home_readings"
    assert opts[:db] == :home
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

  test "falls back when final answer contradicts non-empty tool results" do
    assert {:ok, "fallback answer"} =
             Zaik.AgentChat.respond("what did we ask recently?", %{},
               client: ContradictoryClient,
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

  test "dispatches registered typed home-state tools without an AgentChat branch" do
    {:ok, store} = start_supervised({Zaik.Home.DeviceStore, name: nil})

    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Nursery sensor",
      %{"temperature" => 25.0},
      %{"area_id" => "nursery"}
    )

    assert {:ok, "The nursery is 77°F."} =
             Zaik.AgentChat.respond(
               "What is the nursery temperature?",
               %{device_store: store},
               client: TypedHomeStateClient,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 2}
             )
  end

  test "executes a registered preflighted home plan through the generic agent loop" do
    {:ok, store} = start_supervised({Zaik.Home.DeviceStore, name: nil})

    Zaik.Home.DeviceStore.upsert_device(store, "Left blind", %{"position" => 100}, %{
      "ieee_address" => "left"
    })

    Zaik.Home.DeviceStore.upsert_device(store, "Right blind", %{"position" => 100}, %{
      "ieee_address" => "right"
    })

    context = %{
      device_store: store,
      executor_opts: [modules: [PlanCoverExecutor]],
      test_pid: self()
    }

    assert {:ok, "Both commands were accepted."} =
             Zaik.AgentChat.respond("Prepare the room", context,
               client: HomePlanClient,
               prompt_domain: :home_control,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 2}
             )

    assert_received {:plan_action_executed, "left", %{"state" => "CLOSE"}}
    assert_received {:plan_action_executed, "right", %{"position" => 71}}
  end

  test "does not execute a current-state tool for a historical request" do
    assert {:ok, "The temperature changed by 1°F."} =
             Zaik.AgentChat.respond(
               "What was Lily's temperature change in the past 30 minutes?",
               %{eval_pid: self()},
               client: HistoricalToolCorrectionClient,
               sql_tool: FakeSQLTool,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 2}
             )

    assert_received {:sql_tool_called, query, opts}
    assert query =~ "home_readings"
    assert opts[:db] == :home
    refute_received {:zaik_agent_eval_registered_tool_call, _call}
  end

  test "does not replay a home action through model fallback" do
    assert {:ok, answer} =
             Zaik.AgentChat.respond("Close the office blind", %{test_pid: self()},
               client: ActionFallbackClient,
               control_tool: FakeControlTool,
               prompt_domain: :home_control,
               config: %{
                 enabled: true,
                 model: "small",
                 fallback_enabled: true,
                 fallback_model: "big",
                 max_tool_calls: 3
               }
             )

    assert answer =~ "read-only analysis limit"
    assert_received {:agent_model_called, "small"}
    refute_received {:agent_model_called, "big"}
    assert_received {:control_tool_called, "control_blind", _args}
    refute_received {:control_tool_called, "control_blind", _args}
  end

  test "suppresses an equivalent successful control within one attempt" do
    assert {:ok, "The command was accepted."} =
             Zaik.AgentChat.respond("Close the office blind", %{test_pid: self()},
               client: DuplicateControlClient,
               control_tool: FakeControlTool,
               prompt_domain: :home_control,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    assert_received {:control_tool_called, "control_blind", _args}
    refute_received {:control_tool_called, "control_blind", _args}
  end

  test "suppresses a repeated equivalent action after a failed attempt" do
    assert {:ok, answer} =
             Zaik.AgentChat.respond("Close the office blind", %{test_pid: self()},
               client: DuplicateControlClient,
               control_tool: FailingControlTool,
               prompt_domain: :home_control,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    assert answer =~ "No successful action result"
    assert_received {:failing_control_called, "control_blind", _args}
    refute_received {:failing_control_called, "control_blind", _args}
  end

  test "a successful SQL read does not confirm a home action" do
    assert {:ok, "The command was accepted."} =
             Zaik.AgentChat.respond("Close the office blind", %{test_pid: self()},
               client: SQLDoesNotConfirmControlClient,
               sql_tool: FakeSQLTool,
               control_tool: FakeControlTool,
               prompt_domain: :home_control,
               config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
             )

    assert_received {:sql_tool_called, "SELECT 1", _opts}
    assert_received {:control_tool_called, "control_blind", _args}
  end
end

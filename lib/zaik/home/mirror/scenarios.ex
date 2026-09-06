defmodule Zaik.Home.Mirror.Scenarios do
  @moduledoc """
  Reusable deterministic mirror scenarios for regression and live-model evals.
  """

  alias Zaik.Home.Mirror.Scenario

  def lily_with_history_and_telemetry(opts \\ []) do
    now = Keyword.get(opts, :now, ~U[2026-01-01 12:00:00Z])

    fixture_opts = [
      now: now,
      home_history: lily_home_history(now),
      ops_telemetry: lily_ops_telemetry(now)
    ]

    lily_bedtime_with_ac(Keyword.merge(fixture_opts, opts))
  end

  def lily_bedtime_with_ac(opts \\ []) do
    Scenario.new!(%{
      id: Keyword.get(opts, :id, "lily_bedtime_with_ac"),
      description: "Close Lily's left blind and leave the right blind above the AC.",
      now: Keyword.get(opts, :now, ~U[2026-01-01 00:00:00Z]),
      areas: [%{id: "lily_bedroom", name: "Lily's room"}],
      entities: [
        %{
          id: "eval-sensor",
          name: "Lily's room multi-sensor",
          area_id: "lily_bedroom",
          capabilities: ["temperature", "humidity", "illuminance", "presence"],
          payload: %{
            "temperature" => 25.7777778,
            "humidity" => 56,
            "illuminance" => 220,
            "presence" => true
          }
        },
        %{
          id: "eval-left",
          name: "Lily's bedroom left blind",
          area_id: "lily_bedroom",
          capabilities: ["cover"],
          payload: %{"position" => 100, "state" => "OPEN"},
          metadata: %{"manufacturer" => "Smartwings"}
        },
        %{
          id: "eval-right",
          name: "Lily's bedroom right blind",
          area_id: "lily_bedroom",
          capabilities: ["cover"],
          payload: %{"position" => 100, "state" => "OPEN"},
          metadata: %{"manufacturer" => "Smartwings"}
        }
      ],
      presets: [
        %{
          device: "Lily's bedroom right blind",
          name: "above AC",
          capability: "cover",
          target: %{"position" => 71}
        }
      ],
      home_history: Keyword.get(opts, :home_history, []),
      ops_telemetry: Keyword.get(opts, :ops_telemetry, %{}),
      desired_state: [
        %{
          device: "Lily's bedroom left blind",
          capability: "cover",
          target: %{"state" => "CLOSE"}
        },
        %{
          device: "Lily's bedroom right blind",
          capability: "cover",
          target: %{"position" => 71}
        }
      ],
      faults: Keyword.get(opts, :faults, %{}),
      metadata:
        Map.merge(
          %{max_side_effects: 2, verification_wait_ms: 0},
          Map.new(Keyword.get(opts, :metadata, %{}))
        )
    })
  end

  defp lily_home_history(now) do
    [
      home_reading(now, -10_200, %{"temperature" => 25.0, "humidity" => 54}),
      home_reading(now, -1_740, %{"temperature" => 25.2, "humidity" => 55}),
      home_reading(now, -60, %{
        "temperature" => 25.7777778,
        "humidity" => 56,
        "illuminance" => 220,
        "presence" => true
      }),
      %{
        device: "Lily's bedroom right blind",
        payload: %{"position" => 100, "state" => "OPEN"},
        metadata: %{"source" => "mirror"},
        observed_at: DateTime.add(now, -30, :second)
      }
    ]
  end

  defp home_reading(now, offset_seconds, payload) do
    %{
      device: "Lily's room multi-sensor",
      payload: payload,
      metadata: %{"source" => "mirror", "ieee_address" => "eval-sensor"},
      observed_at: DateTime.add(now, offset_seconds, :second)
    }
  end

  defp lily_ops_telemetry(now) do
    %{
      messages: [
        %{
          id: "eval-message-1",
          session_id: "eval-session",
          role: "user",
          content: "what have we asked you today?",
          channel: "telegram",
          sender_id: "111",
          chat_id: "-100",
          created_at: DateTime.add(now, -600, :second)
        },
        %{
          id: "eval-message-2",
          session_id: "eval-session",
          role: "user",
          content: "how's Lily's room?",
          channel: "telegram",
          sender_id: "222",
          chat_id: "-100",
          created_at: DateTime.add(now, -300, :second)
        }
      ],
      tasks: [
        %{
          id: "task-1",
          type: :llm_prompt,
          status: :failed,
          submitted_at: DateTime.add(now, -7_500, :second),
          completed_at: DateTime.add(now, -7_200, :second),
          error: :timeout
        }
      ],
      agent_chat_runs: [
        %{
          id: "eval-fallback-run",
          prompt: "what have we asked you today?",
          context: %{channel: :telegram, chat_id: "-100"},
          channel: "telegram",
          sender_id: "111",
          chat_id: "-100",
          chat_type: "group",
          session_id: "eval-session",
          primary_model: "qwen3:4b-instruct",
          fallback_model: "qwen3-coder:30b",
          fallback_used: true,
          final_model: "qwen3-coder:30b",
          status: :ok,
          answer: "Fixture answer",
          created_at: DateTime.add(now, -3_600, :second)
        }
      ]
    }
  end
end

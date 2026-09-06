defmodule Zaik.Home.MirrorTest do
  use ExUnit.Case, async: true

  alias Zaik.Home.Mirror.{Runner, Scenario}

  test "runs a preflighted bedtime plan to verified desired state without MQTT" do
    scenario = bedtime_scenario()

    assert {:ok, run} =
             Runner.run(scenario, fn mirror, context ->
               context =
                 Map.merge(context, %{
                   channel: :mirror,
                   chat_id: scenario.id,
                   message_id: "request-1"
                 })

               result =
                 Zaik.Tools.Executor.run(
                   "execute_home_plan",
                   %{
                     "goal" => "bedtime with AC",
                     "actions" => [
                       %{
                         "device" => "Lily's bedroom left blind",
                         "capability" => "cover",
                         "target" => %{"state" => "CLOSE"}
                       },
                       %{
                         "device" => "Lily's bedroom right blind",
                         "capability" => "cover",
                         "target" => %{"preset" => "above AC"}
                       }
                     ]
                   },
                   context
                 )

               assert Zaik.Home.Mirror.side_effect_count(mirror) == 2
               result
             end)

    assert {:ok, result} = run.result
    assert result.status == "verified"
    assert result.verified == true
    assert run.report.passed? == true
    assert run.report.side_effect_count == 2
    assert Enum.all?(result.actions, &(&1.result.adapter == "mirror"))

    assert Enum.map(run.report.actions, & &1.device) == [
             "Lily's bedroom left blind",
             "Lily's bedroom right blind"
           ]
  end

  test "an invalid target fails preflight with zero virtual side effects" do
    scenario = bedtime_scenario()

    assert {:ok, run} =
             Runner.run(scenario, fn _mirror, context ->
               Zaik.Tools.Executor.run(
                 "execute_home_plan",
                 %{
                   "actions" => [
                     %{
                       "device" => "Lily's bedroom left blind",
                       "capability" => "cover",
                       "target" => %{"position" => 101}
                     },
                     %{
                       "device" => "Lily's bedroom right blind",
                       "capability" => "cover",
                       "target" => %{"position" => 71}
                     }
                   ]
                 },
                 Map.merge(context, %{
                   channel: :mirror,
                   chat_id: scenario.id,
                   message_id: "invalid-request"
                 })
               )
             end)

    assert {:error, {:invalid_action_plan, _errors}} = run.result
    assert run.report.side_effect_count == 0
    assert run.report.passed? == false
  end

  test "reports partial completion when a later virtual executor fails" do
    scenario = bedtime_scenario(%{"Lily's bedroom right blind" => :executor_failure})

    assert {:ok, run} =
             Runner.run(scenario, fn _mirror, context ->
               Zaik.Tools.Executor.run(
                 "execute_home_plan",
                 %{
                   "actions" => [
                     %{
                       "device" => "Lily's bedroom left blind",
                       "capability" => "cover",
                       "target" => %{"state" => "CLOSE"}
                     },
                     %{
                       "device" => "Lily's bedroom right blind",
                       "capability" => "cover",
                       "target" => %{"position" => 71}
                     }
                   ]
                 },
                 Map.merge(context, %{
                   channel: :mirror,
                   chat_id: scenario.id,
                   message_id: "partial-request"
                 })
               )
             end)

    assert {:error, {:action_plan_failed, failure}} = run.result
    assert failure.status == "partially_completed"
    assert failure.completed_count == 1
    assert failure.failed.action.device == "Lily's bedroom right blind"
    assert run.report.side_effect_count == 1
    assert run.report.passed? == false
  end

  test "models accepted commands that never converge" do
    scenario = bedtime_scenario(%{"Lily's bedroom left blind" => :never_converges})

    assert {:ok, run} =
             Runner.run(scenario, fn _mirror, context ->
               Zaik.Tools.Executor.run(
                 "control_device",
                 %{
                   "device" => "Lily's bedroom left blind",
                   "capability" => "cover",
                   "target" => %{"state" => "CLOSE"}
                 },
                 Map.merge(context, %{
                   channel: :mirror,
                   chat_id: scenario.id,
                   message_id: "stalled-request"
                 })
               )
             end)

    assert {:ok, result} = run.result
    assert result.status == "accepted"
    assert result.verified == false
    assert result.verification_status == "pending"
    assert run.report.side_effect_count == 1
    assert run.report.passed? == false
  end

  test "virtual time drives verification expiry and retry eligibility without sleeping" do
    scenario =
      Zaik.Home.Mirror.Scenarios.lily_bedtime_with_ac(
        faults: %{
          "Lily's bedroom left blind" => %{
            type: :delayed_convergence,
            delay_ms: 100,
            reported_position: 50
          }
        },
        metadata: %{verification_timeout_ms: 50, verification_wait_ms: 0}
      )

    assert {:ok, run} =
             Runner.run(scenario, fn mirror, context ->
               context =
                 Map.merge(context, %{
                   channel: :mirror,
                   chat_id: scenario.id,
                   message_id: "virtual-retry"
                 })

               {:ok, action} =
                 Zaik.Tools.Executor.run(
                   "control_device",
                   %{
                     "device" => "Lily's bedroom left blind",
                     "capability" => "cover",
                     "target" => %{"state" => "CLOSE"}
                   },
                   context
                 )

               assert action.verification_status == "pending"
               assert %{fired: 2} = Zaik.Home.Mirror.advance(mirror, 100)

               assert {:ok, entry} =
                        Zaik.Home.ActionLedger.lookup(action.action_id, mirror.action_ledger)

               {:ok, decision} =
                 Zaik.Home.ActionRetryPolicy.evaluate(
                   entry,
                   context,
                   settle_ms: 0,
                   cooldown_ms: 0
                 )

               %{action: action, decision: decision, now: Zaik.Home.Mirror.now(mirror)}
             end)

    assert run.result.now == ~U[2026-01-01 00:00:00.100Z]
    assert run.result.decision.eligible == true
    assert run.result.decision.reason == "fresh_state_not_converged"
  end

  test "supports delayed convergence and evaluates final semantic state" do
    scenario =
      bedtime_scenario(%{
        "Lily's bedroom left blind" => %{type: :delayed_convergence, delay_ms: 30}
      })
      |> put_in([Access.key!(:metadata), :verification_wait_ms], 0)

    assert {:ok, run} =
             Runner.run(
               scenario,
               fn _mirror, context ->
                 Zaik.Tools.Executor.run(
                   "control_device",
                   %{
                     "device" => "Lily's bedroom left blind",
                     "capability" => "cover",
                     "target" => %{"state" => "CLOSE"}
                   },
                   Map.merge(context, %{
                     channel: :mirror,
                     chat_id: scenario.id,
                     message_id: "delayed-request"
                   })
                 )
               end,
               settle_ms: 60
             )

    assert {:ok, result} = run.result
    assert result.status == "accepted"
    assert result.verified == false
    assert run.report.passed? == false

    left_check = Enum.find(run.report.checks, &String.contains?(&1.name, "left blind"))
    assert left_check.passed? == true

    left_entity =
      Enum.find(run.report.snapshot.entities, &(&1.name == "Lily's bedroom left blind"))

    assert left_entity.observed_at == "2026-01-01T00:00:00.030Z"
  end

  test "loads isolated production-schema SQLite history and telemetry fixtures" do
    scenario = Zaik.Home.Mirror.Scenarios.lily_with_history_and_telemetry()

    assert {:ok, run} =
             Runner.run(scenario, fn mirror, context ->
               sql_opts = context.sql_tool_opts

               assert File.exists?(mirror.home_db_path)
               assert File.exists?(mirror.ops_db_path)

               {:ok, home} =
                 Zaik.Analytics.SQLTool.run(
                   "SELECT COUNT(*) AS count, MIN(temperature_c) AS minimum, MAX(temperature_c) AS maximum FROM home_readings WHERE device_name = 'Lily''s room multi-sensor' AND temperature_c IS NOT NULL",
                   Keyword.merge(sql_opts, db: :home)
                 )

               {:ok, messages} =
                 Zaik.Analytics.SQLTool.run(
                   "SELECT sender_id, content FROM zaik_messages WHERE chat_id = '-100' ORDER BY created_at",
                   Keyword.merge(sql_opts, db: :ops)
                 )

               {:ok, presets} =
                 Zaik.Analytics.SQLTool.run(
                   "SELECT device_name, preset_name, target_json FROM home_device_presets",
                   Keyword.merge(sql_opts, db: :home)
                 )

               %{
                 home: home,
                 messages: messages,
                 presets: presets,
                 home_db_path: mirror.home_db_path,
                 ops_db_path: mirror.ops_db_path
               }
             end)

    assert run.result.home.rows == [
             %{"count" => 3, "minimum" => 25.0, "maximum" => 25.7777778}
           ]

    assert Enum.map(run.result.messages.rows, & &1["sender_id"]) == ["111", "222"]

    assert run.result.presets.rows == [
             %{
               "device_name" => "Lily's bedroom right blind",
               "preset_name" => "above AC",
               "target_json" => "{\"position\":71}"
             }
           ]

    refute File.exists?(run.result.home_db_path)
    refute File.exists?(run.result.ops_db_path)
  end

  test "rejects malformed scenarios and unavailable declared capabilities" do
    assert {:error, {:invalid_area, _area}} =
             Scenario.new(%{
               id: "bad-area",
               areas: [%{id: "room-without-name"}],
               entities: [],
               desired_state: []
             })

    assert {:error, {:invalid_home_history_reading, _reading}} =
             Scenario.new(%{
               id: "bad-history",
               entities: [],
               home_history: [%{device: "sensor", payload: %{}, observed_at: "not-a-time"}],
               desired_state: []
             })

    assert {:error, {:unknown_ops_telemetry_sections, [:unknown]}} =
             Scenario.new(%{
               id: "bad-ops",
               entities: [],
               ops_telemetry: %{unknown: []},
               desired_state: []
             })

    assert {:error, {:invalid_event, _event}} =
             Scenario.new(%{
               id: "bad-event",
               entities: [],
               events: [%{type: :state_report, at_ms: -1, device: "sensor", payload: %{}}],
               desired_state: []
             })

    scenario =
      Scenario.new!(%{
        id: "bad-capability",
        entities: [
          %{
            id: "sensor",
            name: "Test sensor",
            capabilities: ["humidity"],
            payload: %{"temperature" => 20}
          }
        ],
        desired_state: []
      })

    assert {:error,
            {:invalid_mirror_entity, "Test sensor", {:missing_capabilities, ["humidity"]}}} =
             Zaik.Home.Mirror.start(scenario)
  end

  test "fingerprints scenario contents deterministically" do
    first = bedtime_scenario()
    second = bedtime_scenario()
    assert Scenario.fingerprint(first) == Scenario.fingerprint(second)
  end

  defp bedtime_scenario(faults \\ %{}) do
    Zaik.Home.Mirror.Scenarios.lily_bedtime_with_ac(faults: faults)
  end
end

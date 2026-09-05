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

  test "supports delayed convergence and evaluates final semantic state" do
    scenario =
      bedtime_scenario(%{
        "Lily's bedroom left blind" => %{type: :delayed_convergence, delay_ms: 30}
      })
      |> put_in([Access.key!(:metadata), :verification_wait_ms], 5)

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
  end

  test "rejects malformed scenarios and unavailable declared capabilities" do
    assert {:error, {:invalid_area, _area}} =
             Scenario.new(%{
               id: "bad-area",
               areas: [%{id: "room-without-name"}],
               entities: [],
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

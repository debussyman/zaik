defmodule Zaik.Tools.ExecutorTest do
  use ExUnit.Case, async: true

  defmodule SkillAction do
    @behaviour Zaik.Tool

    def descriptor do
      %{
        name: "skill_action",
        description: "Test skill action",
        input_schema: %{"type" => "object"},
        kind: :action,
        risk: :medium
      }
    end

    def run(_args, _context), do: {:ok, %{status: "accepted"}}
  end

  setup do
    {:ok, ledger} =
      start_supervised({Zaik.Home.ActionLedger, name: nil, db_path: ":memory:"})

    {:ok, supervisor} = start_supervised({Task.Supervisor, name: nil})
    %{ledger: ledger, supervisor: supervisor}
  end

  test "runs actions under supervision and suppresses a replayed ingress action", %{
    ledger: ledger,
    supervisor: supervisor
  } do
    caller = self()
    context = %{channel: :telegram, chat_id: "-100", message_id: 77}
    args = %{"device" => "Office blind", "target" => %{"state" => "CLOSE"}}

    action = fn ->
      send(caller, {:action_process, self()})
      {:ok, %{status: "accepted"}}
    end

    assert {:ok, %{status: "accepted"}} =
             Zaik.Tools.Executor.run_action("control_device", args, context, action,
               ledger: ledger,
               task_supervisor: supervisor
             )

    assert_received {:action_process, action_pid}
    refute action_pid == self()

    assert {:ok, duplicate} =
             Zaik.Tools.Executor.run_action("control_device", args, context, action,
               ledger: ledger,
               task_supervisor: supervisor
             )

    assert duplicate["duplicate"] == true
    refute_received {:action_process, _pid}
  end

  test "injects the ledger correlation ID into action context", %{
    ledger: ledger,
    supervisor: supervisor
  } do
    caller = self()
    context = %{channel: :telegram, chat_id: "-100", message_id: 91}
    args = %{"device" => "Office blind", "target" => %{"position" => 37}}
    expected_id = Zaik.Home.ActionLedger.idempotency_key("control_device", args, context)

    assert {:ok, %{status: "accepted"}} =
             Zaik.Tools.Executor.run_action(
               "control_device",
               args,
               context,
               fn action_context ->
                 send(caller, {:action_id, action_context.action_id})
                 {:ok, %{status: "accepted"}}
               end,
               ledger: ledger,
               task_supervisor: supervisor
             )

    assert_received {:action_id, ^expected_id}
  end

  test "enforces active skill tool and risk declarations", %{
    ledger: ledger,
    supervisor: supervisor
  } do
    base_context = %{
      channel: :telegram,
      chat_id: "-100",
      message_id: 100,
      action_ledger: ledger,
      task_supervisor: supervisor
    }

    denied_tool =
      Map.put(base_context, :active_skills, [
        %{name: "safe skill", risk: "high", allowed_tools: ["another_action"]}
      ])

    assert {:error, {:skill_tool_not_allowed, "safe skill", "skill_action"}} =
             Zaik.Tools.Executor.run("skill_action", %{}, denied_tool,
               registry_opts: [modules: [SkillAction]]
             )

    denied_risk =
      Map.put(base_context, :active_skills, [
        %{name: "low skill", risk: "low", allowed_tools: ["skill_action"]}
      ])

    assert {:error, {:skill_risk_exceeded, "low skill", "low", :medium}} =
             Zaik.Tools.Executor.run("skill_action", %{}, denied_risk,
               registry_opts: [modules: [SkillAction]]
             )

    versioned_goal =
      Map.put(base_context, :active_skills, [
        %{
          name: "versioned goal",
          risk: "medium",
          allowed_tools: ["skill_action"],
          contract: %{goal_id: "bedtime"}
        }
      ])

    assert {:error, {:versioned_goal_requires_evidence_plan, ["bedtime"], "skill_action"}} =
             Zaik.Tools.Executor.run("skill_action", %{}, versioned_goal,
               registry_opts: [modules: [SkillAction]]
             )

    allowed =
      Map.put(base_context, :active_skills, [
        %{name: "medium skill", risk: "medium", allowed_tools: ["skill_action"]}
      ])

    assert {:ok, %{status: "accepted"}} =
             Zaik.Tools.Executor.run("skill_action", %{}, allowed,
               registry_opts: [modules: [SkillAction]]
             )
  end

  test "bounds action execution time", %{ledger: ledger, supervisor: supervisor} do
    assert {:error, :action_timeout} =
             Zaik.Tools.Executor.run_action(
               "control_device",
               %{"device" => "Slow blind"},
               %{channel: :telegram, chat_id: "-100", message_id: 88},
               fn ->
                 Process.sleep(1_000)
                 {:ok, %{status: "accepted"}}
               end,
               ledger: ledger,
               task_supervisor: supervisor,
               timeout_ms: 5
             )
  end
end

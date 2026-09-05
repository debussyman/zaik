defmodule Zaik.Tools.ExecutorTest do
  use ExUnit.Case, async: true

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

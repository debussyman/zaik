defmodule Zaik.TaskWatchdogTest do
  use ExUnit.Case, async: false

  setup do
    watchdog = unique_name("task_watchdog")

    start_supervised!(%{
      id: watchdog,
      start:
        {Zaik.TaskWatchdog, :start_link,
         [[name: watchdog, scan_interval_ms: 3_600_000, dispatch_after_scan?: false]]}
    })

    %{watchdog: watchdog}
  end

  test "re-enqueues queued tasks missing from queue", %{watchdog: watchdog} do
    task = Zaik.Task.new(:echo, %{message: "missing queue"}, id: unique_id("missing"))
    assert {:ok, _task} = Zaik.TaskStore.insert(task)
    refute Zaik.TaskQueue.contains?(task.id)

    assert %{requeued_missing_queued_tasks: 1} = Zaik.TaskWatchdog.scan_now(watchdog)
    assert Zaik.TaskQueue.contains?(task.id)

    cleanup_task(task.id)
  end

  test "removes terminal tasks left in queue", %{watchdog: watchdog} do
    task = Zaik.Task.new(:echo, %{message: "terminal queue"}, id: unique_id("terminal"))
    assert {:ok, _task} = Zaik.TaskStore.insert(task)
    assert :ok = Zaik.TaskQueue.enqueue(task)
    assert {:ok, _task} = Zaik.TaskStore.update(Zaik.Task.mark_succeeded(task, %{ok: true}))

    assert %{removed_terminal_queue_entries: 1} = Zaik.TaskWatchdog.scan_now(watchdog)
    refute Zaik.TaskQueue.contains?(task.id)
  end

  test "fails orphaned running tasks that cannot retry", %{watchdog: watchdog} do
    task =
      Zaik.Task.new(:echo, %{message: "orphan"}, id: unique_id("orphan"))
      |> Map.merge(%{
        status: :running,
        attempts: 1,
        max_retries: 0,
        agent_pid: nil,
        started_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    assert {:ok, _task} = Zaik.TaskStore.insert(task)

    assert %{failed_orphaned_running_tasks: 1} = Zaik.TaskWatchdog.scan_now(watchdog)

    assert {:ok, %{status: :failed, error: {:watchdog, :orphaned_running_dead_pid}}} =
             Zaik.TaskStore.get(task.id)
  end

  test "command processor can trigger watchdog scan" do
    response = Zaik.CommandProcessor.process("watchdog scan")

    assert response =~ "Watchdog scan complete."
    assert response =~ "Requeued missing queued:"
  end

  defp cleanup_task(task_id) do
    Zaik.TaskQueue.remove(task_id)

    with {:ok, task} <- Zaik.TaskStore.get(task_id) do
      Zaik.TaskStore.update(Zaik.Task.mark_cancelled(task))
    end
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp unique_name(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end

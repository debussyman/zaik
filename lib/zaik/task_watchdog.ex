defmodule Zaik.TaskWatchdog do
  @moduledoc """
  Periodically reconciles task-store, queue, dispatcher, and task-agent state.

  The dispatcher remains the primary lifecycle owner. The watchdog is a
  conservative safety net for stale queued/assigned/running state, terminal
  queue entries, and orphaned task agents.
  """

  use GenServer
  require Logger

  @default_scan_interval_ms 30_000
  @default_assigned_stale_after_ms 10_000
  @default_running_stale_after_ms 120_000

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def scan_now(server \\ __MODULE__), do: GenServer.call(server, :scan_now, 30_000)
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @impl true
  def init(opts) do
    state = %{
      scan_interval_ms: Keyword.get(opts, :scan_interval_ms, @default_scan_interval_ms),
      assigned_stale_after_ms:
        Keyword.get(opts, :assigned_stale_after_ms, @default_assigned_stale_after_ms),
      running_stale_after_ms:
        Keyword.get(opts, :running_stale_after_ms, @default_running_stale_after_ms),
      dispatch_after_scan?: Keyword.get(opts, :dispatch_after_scan?, true),
      timer_ref: nil,
      last_scan_at: nil,
      last_summary: empty_summary()
    }

    {:ok, schedule_scan(state)}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call(:scan_now, _from, state) do
    {summary, state} = scan(state)
    {:reply, summary, state}
  end

  @impl true
  def handle_info(:scan, state) do
    {summary, state} = scan(state)

    if changed?(summary) do
      Logger.info("Task watchdog reconciliation: #{inspect(summary)}")
    end

    {:noreply, schedule_scan(state)}
  end

  defp scan(state) do
    summary =
      empty_summary()
      |> reconcile_terminal_queue_entries()
      |> reconcile_queued_tasks()
      |> reconcile_assigned_tasks(state)
      |> reconcile_running_tasks(state)
      |> reconcile_terminal_agents()

    if state.dispatch_after_scan? and dispatch_needed?(summary) do
      safe_dispatch()
    end

    Zaik.TelemetryStore.safe_record_watchdog_scan(summary)

    {summary, %{state | last_scan_at: DateTime.utc_now(), last_summary: summary}}
  end

  defp reconcile_terminal_queue_entries(summary) do
    queue_entries()
    |> Enum.reduce(summary, fn entry, summary ->
      case Zaik.TaskStore.get(entry.task_id) do
        {:ok, task} ->
          if Zaik.Task.terminal?(task) do
            Zaik.TaskQueue.remove(task.id)
            append_event(task, :removed_terminal_queue_entry)
            update_in(summary.removed_terminal_queue_entries, &(&1 + 1))
          else
            summary
          end

        {:error, :not_found} ->
          Zaik.TaskQueue.remove(entry.task_id)
          update_in(summary.removed_missing_queue_entries, &(&1 + 1))
      end
    end)
  end

  defp reconcile_queued_tasks(summary) do
    queued_ids = queue_entries() |> Enum.map(& &1.task_id) |> MapSet.new()

    task_store_tasks()
    |> Enum.filter(&(&1.status == :queued))
    |> Enum.reduce(summary, fn task, summary ->
      if MapSet.member?(queued_ids, task.id) do
        summary
      else
        case Zaik.TaskQueue.enqueue(task) do
          :ok ->
            append_event(task, :requeued_missing_queued_task)
            update_in(summary.requeued_missing_queued_tasks, &(&1 + 1))

          {:error, :already_enqueued} ->
            summary
        end
      end
    end)
  end

  defp reconcile_assigned_tasks(summary, state) do
    task_store_tasks()
    |> Enum.filter(&(&1.status == :assigned))
    |> Enum.reduce(summary, fn task, summary ->
      if stale?(task.submitted_at, state.assigned_stale_after_ms) do
        retry_or_fail(
          task,
          :stale_assigned,
          summary,
          :requeued_stale_assigned_tasks,
          :failed_stale_assigned_tasks
        )
      else
        summary
      end
    end)
  end

  defp reconcile_running_tasks(summary, state) do
    owned_ids = dispatcher_running_ids()

    task_store_tasks()
    |> Enum.filter(&(&1.status == :running))
    |> Enum.reduce(summary, fn task, summary ->
      cond do
        dead_or_missing_pid?(task.agent_pid) ->
          retry_or_fail(
            task,
            :orphaned_running_dead_pid,
            summary,
            :requeued_orphaned_running_tasks,
            :failed_orphaned_running_tasks
          )

        not MapSet.member?(owned_ids, task.id) ->
          terminate_pid(task.agent_pid)

          retry_or_fail(
            task,
            :orphaned_running_unowned,
            summary,
            :requeued_orphaned_running_tasks,
            :failed_orphaned_running_tasks
          )

        stale?(task.started_at, state.running_stale_after_ms) ->
          # Dispatcher timeouts should normally handle this first. This branch
          # is for cases where the timeout message was lost with dispatcher state.
          terminate_pid(task.agent_pid)

          retry_or_fail(
            task,
            :stale_running,
            summary,
            :requeued_stale_running_tasks,
            :failed_stale_running_tasks
          )

        true ->
          summary
      end
    end)
  end

  defp reconcile_terminal_agents(summary) do
    task_store_tasks()
    |> Enum.filter(&Zaik.Task.terminal?/1)
    |> Enum.reduce(summary, fn task, summary ->
      case Registry.lookup(Zaik.Agent.Registry, {:task_agent, task.id}) do
        [] ->
          summary

        agents ->
          Enum.each(agents, fn {pid, _value} -> terminate_pid(pid) end)
          append_event(task, :terminated_terminal_task_agent)
          update_in(summary.terminated_terminal_task_agents, &(&1 + length(agents)))
      end
    end)
  rescue
    ArgumentError -> summary
  end

  defp retry_or_fail(task, reason, summary, requeued_key, failed_key) do
    if task.attempts <= task.max_retries do
      queued = %{Zaik.Task.mark_queued(task) | started_at: nil, completed_at: nil, error: nil}
      Zaik.TaskStore.update(queued)
      Zaik.TaskQueue.enqueue(queued)
      append_event(queued, {:watchdog_requeued, reason})
      update_in(summary, [requeued_key], &(&1 + 1))
    else
      failed = Zaik.Task.mark_failed(task, {:watchdog, reason})
      Zaik.TaskStore.update(failed)
      append_event(failed, {:watchdog_failed, reason})
      update_in(summary, [failed_key], &(&1 + 1))
    end
  end

  defp task_store_tasks do
    Zaik.list_tasks()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp queue_entries do
    Zaik.TaskQueue.entries()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp dispatcher_running_ids do
    case Zaik.Dispatcher.state() do
      %{running: running} -> running |> Map.keys() |> MapSet.new()
      _ -> MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  catch
    :exit, _ -> MapSet.new()
  end

  defp safe_dispatch do
    Zaik.Dispatcher.dispatch_now()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp dead_or_missing_pid?(nil), do: true
  defp dead_or_missing_pid?(pid) when is_pid(pid), do: not Process.alive?(pid)
  defp dead_or_missing_pid?(_), do: true

  defp terminate_pid(nil), do: :ok

  defp terminate_pid(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      DynamicSupervisor.terminate_child(Zaik.Agent.DynamicSupervisor, pid)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp stale?(nil, _threshold_ms), do: false

  defp stale?(%DateTime{} = at, threshold_ms) do
    DateTime.diff(DateTime.utc_now(), at, :millisecond) >= threshold_ms
  end

  defp append_event(%Zaik.Task{session_id: nil}, _event), do: :ok

  defp append_event(%Zaik.Task{} = task, event) do
    Zaik.SessionStore.append(task.session_id, %{
      type: "task_event",
      taskId: task.id,
      taskType: to_string(task.type),
      event: inspect(event),
      source: "watchdog"
    })
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp schedule_scan(state) do
    timer_ref = Process.send_after(self(), :scan, state.scan_interval_ms)
    %{state | timer_ref: timer_ref}
  end

  defp changed?(summary), do: summary != empty_summary()

  defp dispatch_needed?(summary) do
    summary.requeued_missing_queued_tasks +
      summary.requeued_stale_assigned_tasks +
      summary.requeued_orphaned_running_tasks +
      summary.requeued_stale_running_tasks > 0
  end

  defp empty_summary do
    %{
      requeued_missing_queued_tasks: 0,
      removed_terminal_queue_entries: 0,
      removed_missing_queue_entries: 0,
      requeued_stale_assigned_tasks: 0,
      failed_stale_assigned_tasks: 0,
      requeued_orphaned_running_tasks: 0,
      failed_orphaned_running_tasks: 0,
      requeued_stale_running_tasks: 0,
      failed_stale_running_tasks: 0,
      terminated_terminal_task_agents: 0
    }
  end
end

defmodule Zaik.Dispatcher do
  @moduledoc """
  Dispatches queued tasks to dynamically supervised task agents.
  """

  use GenServer

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def dispatch_now(server \\ __MODULE__), do: GenServer.call(server, :dispatch_now)
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  def cancel_task(server \\ __MODULE__, task_id),
    do: GenServer.call(server, {:cancel_task, task_id})

  @impl true
  def init(opts) do
    {:ok, %{max_concurrency: Keyword.get(opts, :max_concurrency, 4), running: %{}}}
  end

  @impl true
  def handle_call(:dispatch_now, _from, state) do
    {:reply, :ok, dispatch_tasks(state)}
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:cancel_task, task_id}, _from, state) do
    case Map.pop(state.running, task_id) do
      {nil, _running} ->
        {:reply, {:error, :not_running}, state}

      {%{pid: pid} = running, running_map} ->
        cancel_running_refs(running)

        if Process.alive?(pid),
          do: DynamicSupervisor.terminate_child(Zaik.Agent.DynamicSupervisor, pid)

        with {:ok, task} <- Zaik.TaskStore.get(task_id) do
          Zaik.TaskStore.update(Zaik.Task.mark_cancelled(task))
        end

        {:reply, {:ok, :cancelled}, dispatch_tasks(%{state | running: running_map})}
    end
  end

  @impl true
  def handle_info(:dispatch_now, state), do: {:noreply, dispatch_tasks(state)}

  def handle_info({:task_complete, task_id, result}, state) do
    {:noreply, state |> complete_task(task_id, result) |> dispatch_tasks()}
  end

  def handle_info({:task_failed, task_id, reason}, state) do
    {:noreply, state |> fail_task(task_id, reason) |> dispatch_tasks()}
  end

  def handle_info({:task_timeout, task_id}, state) do
    {:noreply, state |> timeout_task(task_id) |> dispatch_tasks()}
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, state) do
    # Normal task agents report completion/failure before exiting. If the
    # completion message is still in the mailbox, leave state intact and let it
    # handle cleanup. Stale DOWN messages after cleanup are ignored.
    if running_by_ref(state, ref), do: {:noreply, state}, else: {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case running_by_ref(state, ref) do
      {task_id, _running} ->
        {:noreply, state |> fail_task(task_id, {:agent_crashed, reason}) |> dispatch_tasks()}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp dispatch_tasks(state) do
    if map_size(state.running) < state.max_concurrency do
      case dispatch_one(state) do
        {:dispatched, next_state} -> dispatch_tasks(next_state)
        {:idle, next_state} -> next_state
      end
    else
      state
    end
  end

  defp dispatch_one(state) do
    case Zaik.TaskQueue.dequeue() do
      :empty ->
        {:idle, state}

      {:ok, task_id} ->
        case Zaik.TaskStore.get(task_id) do
          {:ok, %{status: :cancelled}} -> {:dispatched, state}
          {:ok, task} -> start_task(state, task)
          {:error, :not_found} -> {:dispatched, state}
        end
    end
  end

  defp start_task(state, task) do
    with {:ok, agent_module} <- Zaik.TaskResolver.resolve(task),
         task = task |> Zaik.Task.mark_assigned(agent_module) |> Zaik.Task.increment_attempts(),
         {:ok, _task} <- Zaik.TaskStore.update(task),
         {:ok, pid} <- Zaik.Agent.DynamicSupervisor.start_task_agent(task, agent_module, self()) do
      monitor_ref = Process.monitor(pid)
      timeout_ref = Process.send_after(self(), {:task_timeout, task.id}, task.timeout_ms)
      running = %{pid: pid, monitor_ref: monitor_ref, timeout_ref: timeout_ref}

      running_task = Zaik.Task.mark_running(task, pid)
      {:ok, _task} = Zaik.TaskStore.update(running_task)

      {:dispatched, %{state | running: Map.put(state.running, task.id, running)}}
    else
      {:error, reason} ->
        mark_non_running_failed(task, reason)
        {:dispatched, state}
    end
  end

  defp complete_task(state, task_id, result) do
    case pop_running(state, task_id) do
      {nil, state} ->
        state

      {_running, state} ->
        with {:ok, task} <- Zaik.TaskStore.get(task_id) do
          succeeded = Zaik.Task.mark_succeeded(task, result)
          {:ok, _task} = Zaik.TaskStore.update(succeeded)

          if succeeded.session_id do
            Zaik.MemoryStore.append_task_result(succeeded.session_id, succeeded, result)
          end
        end

        state
    end
  end

  defp fail_task(state, task_id, reason) do
    case pop_running(state, task_id) do
      {nil, state} ->
        state

      {_running, state} ->
        retry_or_finish_failure(state, task_id, reason)
    end
  end

  defp timeout_task(state, task_id) do
    case pop_running(state, task_id) do
      {nil, state} ->
        state

      {%{pid: pid}, state} ->
        if Process.alive?(pid),
          do: DynamicSupervisor.terminate_child(Zaik.Agent.DynamicSupervisor, pid)

        retry_or_finish_timeout(state, task_id)
    end
  end

  defp retry_or_finish_failure(state, task_id, reason) do
    with {:ok, task} <- Zaik.TaskStore.get(task_id) do
      if task.attempts <= task.max_retries do
        requeue_task(task)
      else
        Zaik.TaskStore.update(Zaik.Task.mark_failed(task, reason))
      end
    end

    state
  end

  defp retry_or_finish_timeout(state, task_id) do
    with {:ok, task} <- Zaik.TaskStore.get(task_id) do
      if task.attempts <= task.max_retries do
        requeue_task(task)
      else
        Zaik.TaskStore.update(Zaik.Task.mark_timed_out(task))
      end
    end

    state
  end

  defp requeue_task(task) do
    queued = %{Zaik.Task.mark_queued(task) | started_at: nil, completed_at: nil, error: nil}
    {:ok, _task} = Zaik.TaskStore.update(queued)
    Zaik.TaskQueue.enqueue(queued)
  end

  defp mark_non_running_failed(task, reason) do
    Zaik.TaskStore.update(Zaik.Task.mark_failed(task, reason))
  end

  defp pop_running(state, task_id) do
    {running, running_map} = Map.pop(state.running, task_id)
    if running, do: cancel_running_refs(running)
    {running, %{state | running: running_map}}
  end

  defp cancel_running_refs(%{monitor_ref: monitor_ref, timeout_ref: timeout_ref}) do
    Process.cancel_timer(timeout_ref)
    Process.demonitor(monitor_ref, [:flush])
  end

  defp running_by_ref(state, ref) do
    Enum.find(state.running, fn {_task_id, running} -> running.monitor_ref == ref end)
  end
end

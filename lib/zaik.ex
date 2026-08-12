defmodule Zaik do
  @moduledoc """
  Zaik is a personal AI agent runtime inspired by OpenClaw, built with Elixir's actor system.

  The system is designed to run multiple AI agents that can:
  - Process messages 
  - Handle periodic ticks
  - Store state
  - Communicate with each other
  """

  @doc """
  Start the Zaik system with all required supervisors and agents.
  """
  def start do
    Application.start(:zaik)
  end

  @doc """
  Stop the Zaik system.
  """
  def stop do
    Application.stop(:zaik)
  end

  @doc """
  Create a filesystem-backed session.
  """
  def create_session(opts \\ []) do
    Zaik.SessionStore.create(opts)
  end

  @doc """
  List filesystem-backed sessions.
  """
  def list_sessions(opts \\ []) do
    Zaik.SessionStore.list(opts)
  end

  @doc """
  Build context from a session's active branch.
  """
  def get_session_context(session_id, opts \\ []) do
    Zaik.ContextBuilder.build(session_id, opts)
  end

  @doc """
  Return a structured runtime snapshot of the harness.
  """
  def snapshot, do: Zaik.Observability.snapshot()

  @doc """
  Return top-level harness health.
  """
  def health, do: Zaik.Observability.health()

  @doc """
  Return task counts by status.
  """
  def task_summary, do: Zaik.Observability.task_summary()

  @doc """
  Run the task watchdog reconciliation immediately.
  """
  def watchdog_scan, do: Zaik.TaskWatchdog.scan_now()

  @doc """
  Return the task watchdog state.
  """
  def watchdog_state, do: Zaik.TaskWatchdog.state()

  @doc """
  Submit a task to the harness.
  """
  def submit_task(type, payload, opts \\ []) do
    task = Zaik.Task.new(type, payload, opts)

    # Store the task in the task store first
    case Zaik.TaskStore.insert(task) do
      {:ok, _} ->
        # Add to session memory if session-scoped
        if task.session_id do
          # Append task to session's memory
          Zaik.MemoryStore.append_task(task, task.session_id)
        end

        # Enqueue and dispatch
        Zaik.TaskQueue.enqueue(task)
        Zaik.Dispatcher.dispatch_now()
        {:ok, task.id}

      error ->
        error
    end
  end

  @doc """
  Await completion of a task.
  """
  def await_task(task_id, timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_task(task_id, deadline)
  end

  @doc """
  Cancel a queued task.
  """
  def cancel_task(task_id) do
    case Zaik.TaskStore.get(task_id) do
      {:ok, %Zaik.Task{status: :queued} = task} ->
        Zaik.TaskQueue.remove(task_id)
        Zaik.TaskStore.update(Zaik.Task.mark_cancelled(task))
        {:ok, :cancelled}

      {:ok, %Zaik.Task{status: :running}} ->
        Zaik.Dispatcher.cancel_task(task_id)

      {:ok, %Zaik.Task{status: status}}
      when status in [:succeeded, :failed, :cancelled, :timed_out] ->
        {:error, {:already_terminal, status}}

      {:ok, %Zaik.Task{status: status}} ->
        {:error, {:cannot_cancel, status}}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Fetch a task by ID.
  """
  def get_task(task_id) do
    Zaik.TaskStore.get(task_id)
  end

  @doc """
  List tasks from the in-memory task store.
  """
  def list_tasks(opts \\ []) do
    Zaik.TaskStore.list(Zaik.TaskStore, opts)
  end

  @doc """
  Get the current task queue size.
  """
  def queue_size do
    Zaik.TaskQueue.size()
  end

  @doc """
  Get a greeting from the hello world agent.
  """
  def hello do
    Zaik.Agent.HelloWorld.hello()
  end

  @doc """
  Send a message to the hello world agent.
  """
  def send_message(message) do
    Zaik.Agent.HelloWorld.send_message(message)
  end

  defp do_await_task(task_id, deadline) do
    case Zaik.TaskStore.get(task_id) do
      {:ok, %Zaik.Task{status: :succeeded, result: result}} ->
        {:ok, result}

      {:ok, %Zaik.Task{status: :failed, error: error}} ->
        {:error, {:task_failed, error}}

      {:ok, %Zaik.Task{status: :cancelled}} ->
        {:error, :cancelled}

      {:ok, %Zaik.Task{status: :timed_out}} ->
        {:error, :task_timed_out}

      {:ok, _task} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(20)
          do_await_task(task_id, deadline)
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end

# Task Harness Enhancement: Stale Task Detection

## Current Gap Analysis

The existing task harness implementation plan does not include any mechanism for detecting and handling stale or stalled tasks. Tasks that become stuck in running state due to agent failures, system crashes, or other issues would remain in the system indefinitely.

## Proposed Enhancement

### 1. Stale Task Detection System

Add a scheduled cleanup process to identify and handle stale tasks:

```elixir
defmodule Zaik.TaskCleanup do
  use GenServer

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :check_interval, 60_000) # Check every minute
    schedule_next_check(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:check_stale_tasks, state) do
    check_and_cleanup_stale_tasks()
    schedule_next_check(state.interval)
    {:noreply, state}
  end

  defp check_and_cleanup_stale_tasks do
    # Scan task store for tasks that are stuck
    # Tasks with status :running but no recent activity
    # Tasks that have exceeded their timeout

    {:ok, stale_tasks} = Zaik.TaskStore.list(%{status: :running, stale_threshold: 300_000})
    
    Enum.each(stale_tasks, fn task ->
      case handle_stale_task(task) do
        :timed_out -> 
          Zaik.TaskStore.update_status(task.id, :timed_out)
          Zaik.Dispatcher.retry_task(task)
        :failed -> 
          Zaik.TaskStore.update_status(task.id, :failed)
          Zaik.Dispatcher.retry_task(task)
      end
    end)
  end

  defp handle_stale_task(task) do
    # Check if agent process is still alive
    case :erlang.process_info(task.agent_pid) do
      {:status, :running} -> :running  # Task still active
      nil -> :timed_out  # Process died
      _ -> :failed  # Error condition
    end
  end

  defp schedule_next_check(interval) do
    Process.send_after(self(), :check_stale_tasks, interval)
  end
end
```

### 2. Enhanced Task Structure

Update the task definition to include tracking for stale detection:

```elixir
defmodule Zaik.Task do
  defstruct [
    :id,
    :type,
    :payload,
    :priority,
    :status,
    :agent_module,
    :agent_pid,
    :result,
    :error,
    :submitted_at,
    :started_at,
    :completed_at,
    :last_activity,
    timeout_ms: 60_000,
    max_retries: 0,
    attempts: 0,
    metadata: %{},
    stale_check_interval: 300_000,  # 5 minutes default
    max_stale_time: 1_800_000        # 30 minutes default
  ]
end
```

### 3. Integration with Application

Add cleanup supervisor to the application:

```elixir
defmodule Zaik.Application do
  @moduledoc """
  The Zaik Application.

  This module defines the root supervision tree for the Zaik system.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Zaik.Clock,
      Zaik.Agent.Supervisor,
      Zaik.TaskStore,
      Zaik.TaskQueue,
      Zaik.Agent.DynamicSupervisor,
      Zaik.Dispatcher,
      Zaik.TaskCleanup,  # Add the cleanup process
      Zaik.TaskRegistry, # Add the registry (if using separate one)
    ]

    opts = [strategy: :one_for_one, name: Zaik.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## Implementation Details

### 1. What to Detect:
- Tasks that have been running longer than their timeout
- Tasks that are running but show no activity
- Tasks where the associated agent process no longer exists
- Tasks that were started but never progressed for extended periods

### 2. Detection Logic:
- Monitor `last_activity` timestamps on tasks
- Ping running agents to ensure they're still responsive
- Query process information to verify agent processes exist
- Compare current time with task start time + timeout

### 3. Response Actions:
- Mark tasks as `:timed_out` or `:failed`
- Attempt to retry the task if configured
- Send notifications for critical failures
- Log events for debugging

### 4. Configuration Options:
- `check_interval`: How often to scan for stale tasks
- `stale_threshold`: Time threshold to consider a task stale
- `max_stale_time`: Maximum time before considering a task permanently failed
- `cleanup_policy`: What to do when stale tasks are detected

## Benefits

1. **System Reliability**: Prevents resource leakage from stuck tasks
2. **Operational Health**: Maintains clean task state and system performance  
3. **Error Recovery**: Proper handling of system failures without manual intervention
4. **Monitoring**: Provides better observability into task system health

This enhancement is crucial for a production system and should be added to Phase 7 of the implementation plan to ensure system stability.
defmodule Zaik.Observability do
  @moduledoc """
  Structured introspection for the Zaik harness.

  This module is intentionally read-only. It gives command processors,
  watchdogs, and remote control surfaces a common view of runtime state.
  """

  @statuses [:queued, :assigned, :running, :succeeded, :failed, :cancelled, :timed_out]

  def snapshot do
    %{
      status: health().status,
      node: Node.self(),
      time: DateTime.utc_now(),
      queue: queue_summary(),
      tasks: task_summary(),
      dispatcher: dispatcher_summary(),
      agents: agent_summary(),
      sessions: session_summary(limit: 5)
    }
  end

  def health do
    dispatcher = dispatcher_summary()

    status =
      cond do
        not process_alive?(Zaik.TaskStore) -> :degraded
        not process_alive?(Zaik.TaskQueue) -> :degraded
        not dispatcher.alive? -> :degraded
        true -> :ok
      end

    %{
      status: status,
      task_store_alive?: process_alive?(Zaik.TaskStore),
      task_queue_alive?: process_alive?(Zaik.TaskQueue),
      dispatcher_alive?: dispatcher.alive?,
      session_store_alive?: process_alive?(Zaik.SessionStore)
    }
  end

  def task_summary do
    tasks = safe_call(fn -> Zaik.TaskStore.list() end, [])
    counts = tasks |> Enum.frequencies_by(& &1.status)

    base = Map.new(@statuses, &{&1, 0})
    Map.merge(base, counts)
  end

  def queue_summary do
    %{size: safe_call(fn -> Zaik.TaskQueue.size() end, 0)}
  end

  def dispatcher_summary do
    if process_alive?(Zaik.Dispatcher) do
      state = safe_call(fn -> Zaik.Dispatcher.state() end, %{max_concurrency: nil, running: %{}})
      running = Map.get(state, :running, %{})

      %{
        alive?: true,
        max_concurrency: Map.get(state, :max_concurrency),
        running_count: map_size(running),
        running_task_ids: Map.keys(running)
      }
    else
      %{
        alive?: false,
        max_concurrency: nil,
        running_count: 0,
        running_task_ids: []
      }
    end
  end

  def agent_summary do
    agents = task_agents()

    %{
      registered_count: length(agents),
      task_agents: agents
    }
  end

  def session_summary(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    sessions =
      safe_call(fn -> Zaik.SessionStore.list() end, [])
      |> Enum.take(limit)
      |> Enum.map(fn session ->
        %{
          id: session.id,
          scope: session.scope,
          cwd: session.cwd,
          updated_at: session.updated_at,
          metadata: session.metadata
        }
      end)

    %{
      count: length(sessions),
      recent: sessions
    }
  end

  defp task_agents do
    if process_alive?(Zaik.Agent.Registry) do
      Zaik.Agent.Registry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
      |> Enum.flat_map(fn
        {{:task_agent, task_id}, pid, _value} ->
          [%{task_id: task_id, pid: inspect(pid), alive?: Process.alive?(pid)}]

        _other ->
          []
      end)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp process_alive?(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp safe_call(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end
end

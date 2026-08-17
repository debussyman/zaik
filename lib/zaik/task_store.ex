defmodule Zaik.TaskStore do
  @moduledoc """
  In-memory task state and result store.
  """

  use GenServer

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def insert(server \\ __MODULE__, %Zaik.Task{} = task) do
    GenServer.call(server, {:insert, task})
  end

  def get(server \\ __MODULE__, task_id) do
    GenServer.call(server, {:get, task_id})
  end

  def update(server \\ __MODULE__, %Zaik.Task{} = task) do
    GenServer.call(server, {:update, task})
  end

  def complete(server \\ __MODULE__, task_id, result) do
    GenServer.call(server, {:complete, task_id, result})
  end

  def fail(server \\ __MODULE__, task_id, reason) do
    GenServer.call(server, {:fail, task_id, reason})
  end

  def list(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:list, opts})
  end

  @impl true
  def init(_opts), do: {:ok, %{tasks: %{}}}

  @impl true
  def handle_call({:insert, task}, _from, state) do
    if Map.has_key?(state.tasks, task.id) do
      {:reply, {:error, :already_exists}, state}
    else
      Zaik.TelemetryStore.safe_record_task(task, :insert)
      {:reply, {:ok, task}, put_task(state, task)}
    end
  end

  def handle_call({:get, task_id}, _from, state) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, task} -> {:reply, {:ok, task}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:update, task}, _from, state) do
    if Map.has_key?(state.tasks, task.id) do
      Zaik.TelemetryStore.safe_record_task(task, :update)
      {:reply, {:ok, task}, put_task(state, task)}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:complete, task_id, result}, _from, state) do
    update_existing(state, task_id, &Zaik.Task.mark_succeeded(&1, result))
  end

  def handle_call({:fail, task_id, reason}, _from, state) do
    update_existing(state, task_id, &Zaik.Task.mark_failed(&1, reason))
  end

  def handle_call({:list, opts}, _from, state) do
    tasks =
      state.tasks
      |> Map.values()
      |> filter(:status, Keyword.get(opts, :status))
      |> filter(:type, Keyword.get(opts, :type))
      |> Enum.sort_by(& &1.submitted_at, DateTime)

    {:reply, tasks, state}
  end

  defp update_existing(state, task_id, fun) do
    case Map.fetch(state.tasks, task_id) do
      {:ok, task} ->
        updated = fun.(task)
        Zaik.TelemetryStore.safe_record_task(updated, :status_change)
        {:reply, {:ok, updated}, put_task(state, updated)}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp put_task(state, task), do: %{state | tasks: Map.put(state.tasks, task.id, task)}

  defp filter(tasks, _field, nil), do: tasks
  defp filter(tasks, field, value), do: Enum.filter(tasks, &(Map.fetch!(&1, field) == value))
end

defmodule Zaik.TaskQueue do
  @moduledoc """
  GenServer-backed priority queue for task IDs.

  Higher priority values are dequeued first. Tasks with equal priority are
  dequeued FIFO by enqueue sequence.
  """

  use GenServer

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def enqueue(server \\ __MODULE__, %Zaik.Task{} = task) do
    GenServer.call(server, {:enqueue, task})
  end

  def dequeue(server \\ __MODULE__) do
    GenServer.call(server, :dequeue)
  end

  def peek(server \\ __MODULE__) do
    GenServer.call(server, :peek)
  end

  def size(server \\ __MODULE__) do
    GenServer.call(server, :size)
  end

  def remove(server \\ __MODULE__, task_id) do
    GenServer.call(server, {:remove, task_id})
  end

  @impl true
  def init(_opts), do: {:ok, %{entries: [], seq: 0}}

  @impl true
  def handle_call({:enqueue, task}, _from, state) do
    if Enum.any?(state.entries, &(&1.task_id == task.id)) do
      {:reply, {:error, :already_enqueued}, state}
    else
      entry = %{
        task_id: task.id,
        priority: task.priority,
        enqueued_at: DateTime.utc_now(),
        seq: state.seq
      }

      entries = [entry | state.entries] |> sort_entries()
      {:reply, :ok, %{state | entries: entries, seq: state.seq + 1}}
    end
  end

  def handle_call(:dequeue, _from, %{entries: []} = state), do: {:reply, :empty, state}

  def handle_call(:dequeue, _from, %{entries: [entry | rest]} = state) do
    {:reply, {:ok, entry.task_id}, %{state | entries: rest}}
  end

  def handle_call(:peek, _from, %{entries: []} = state), do: {:reply, :empty, state}

  def handle_call(:peek, _from, %{entries: [entry | _]} = state) do
    {:reply, {:ok, entry.task_id}, state}
  end

  def handle_call(:size, _from, state), do: {:reply, length(state.entries), state}

  def handle_call({:remove, task_id}, _from, state) do
    {removed, entries} = Enum.split_with(state.entries, &(&1.task_id == task_id))
    reply = if removed == [], do: {:error, :not_found}, else: :ok
    {:reply, reply, %{state | entries: entries}}
  end

  defp sort_entries(entries) do
    Enum.sort_by(entries, &{-&1.priority, &1.seq})
  end
end

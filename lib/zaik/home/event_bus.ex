defmodule Zaik.Home.EventBus do
  @moduledoc """
  Monitored local fanout for accepted canonical home events.
  """

  use GenServer

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put_new(server_opts, :name, __MODULE__))
  end

  def subscribe(server \\ __MODULE__, subscriber \\ self()),
    do: GenServer.call(server, {:subscribe, subscriber})

  def publish(event, server \\ __MODULE__) when is_map(event),
    do: GenServer.cast(server, {:publish, event})

  @impl true
  def init(_opts), do: {:ok, %{subscribers: %{}}}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) when is_pid(pid) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)
      {:reply, :ok, put_in(state, [:subscribers, pid], ref)}
    end
  end

  @impl true
  def handle_cast({:publish, event}, state) do
    Enum.each(Map.keys(state.subscribers), &send(&1, {:zaik_home_event, event}))
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state =
      case Map.get(state.subscribers, pid) do
        ^ref -> update_in(state.subscribers, &Map.delete(&1, pid))
        _ -> state
      end

    {:noreply, state}
  end
end

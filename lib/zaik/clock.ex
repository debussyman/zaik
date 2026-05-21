defmodule Zaik.Clock do
  @moduledoc """
  A simple clock that sends periodic tick messages to registered agents.
  """

  use GenServer

  # Client API

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def start_tick_interval(server \\ __MODULE__, interval_ms) do
    GenServer.cast(server, {:start_tick, interval_ms})
  end

  def stop_tick_interval(server \\ __MODULE__) do
    GenServer.cast(server, :stop_tick)
  end

  def state(server \\ __MODULE__) do
    GenServer.call(server, :state)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    {:ok, %{timer_ref: nil, interval: nil, agents: Keyword.get(opts, :agents, [])}}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:start_tick, interval_ms}, state)
      when is_integer(interval_ms) and interval_ms > 0 do
    cancel_timer(state.timer_ref)
    timer_ref = Process.send_after(self(), :tick, interval_ms)

    {:noreply, %{state | timer_ref: timer_ref, interval: interval_ms}}
  end

  def handle_cast(:stop_tick, state) do
    cancel_timer(state.timer_ref)
    {:noreply, %{state | timer_ref: nil, interval: nil}}
  end

  @impl true
  def handle_info(:tick, %{interval: interval} = state)
      when is_integer(interval) and interval > 0 do
    Enum.each(state.agents, fn agent -> send(agent, :tick) end)
    timer_ref = Process.send_after(self(), :tick, interval)

    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info(:tick, state) do
    {:noreply, %{state | timer_ref: nil}}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer_ref), do: Process.cancel_timer(timer_ref)
end

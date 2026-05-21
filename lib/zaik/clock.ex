defmodule Zaik.Clock do
  @moduledoc """
  A simple clock that sends periodic tick messages to agents.
  """

  use GenServer

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_tick_interval(interval_ms) do
    GenServer.cast(__MODULE__, {:start_tick, interval_ms})
  end

  def stop_tick_interval do
    GenServer.cast(__MODULE__, :stop_tick)
  end

  # Server Callbacks

  def init(_opts) do
    {:ok, %{timer_ref: nil, interval: 0}}
  end

  def handle_cast({:start_tick, interval_ms}, state) do
    # Cancel existing timer
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    
    # Start new timer
    timer_ref = Process.send_after(self(), :tick, interval_ms)
    
    {:noreply, %{state | timer_ref: timer_ref, interval: interval_ms}}
  end

  def handle_cast(:stop_tick, state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    {:noreply, %{state | timer_ref: nil, interval: 0}}
  end

  def handle_info(:tick, state) do
    # Send tick to all supervised agents
    broadcast_tick_to_agents()
    
    # Reschedule the timer
    timer_ref = Process.send_after(self(), :tick, state.interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  defp broadcast_tick_to_agents() do
    # In a more complex system, we'd enumerate all active agents and send them ticks
    # For now, we'll just emit a simple message
    IO.puts("Clock tick: #{DateTime.utc_now()}")
  end
end
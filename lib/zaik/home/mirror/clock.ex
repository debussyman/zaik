defmodule Zaik.Home.Mirror.Clock do
  @moduledoc """
  Manually advanced deterministic clock and timer queue for mirror scenarios.
  """

  use GenServer

  def start_link(opts) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def now(server), do: GenServer.call(server, :now)
  def monotonic_ms(server), do: GenServer.call(server, :monotonic_ms)

  def send_after(server, target, message, delay_ms)
      when is_pid(target) and is_integer(delay_ms) and delay_ms >= 0 do
    GenServer.call(server, {:send_after, target, message, delay_ms})
  end

  def advance(server, milliseconds) when is_integer(milliseconds) and milliseconds >= 0 do
    GenServer.call(server, {:advance, milliseconds})
  end

  def pending(server), do: GenServer.call(server, :pending)

  @impl true
  def init(opts) do
    now = Keyword.get(opts, :now, ~U[2026-01-01 00:00:00Z])

    {:ok, %{now: now, monotonic_ms: 0, next_sequence: 0, timers: []}}
  end

  @impl true
  def handle_call(:now, _from, state), do: {:reply, state.now, state}
  def handle_call(:monotonic_ms, _from, state), do: {:reply, state.monotonic_ms, state}
  def handle_call(:pending, _from, state), do: {:reply, public_timers(state.timers), state}

  def handle_call({:send_after, target, message, delay_ms}, _from, state) do
    sequence = state.next_sequence

    timer = %{
      id: {state.monotonic_ms + delay_ms, sequence},
      due_ms: state.monotonic_ms + delay_ms,
      sequence: sequence,
      target: target,
      message: message
    }

    timers = Enum.sort_by([timer | state.timers], &{&1.due_ms, &1.sequence})
    {:reply, timer.id, %{state | timers: timers, next_sequence: sequence + 1}}
  end

  def handle_call({:advance, milliseconds}, _from, state) do
    target_ms = state.monotonic_ms + milliseconds
    {due, pending} = Enum.split_with(state.timers, &(&1.due_ms <= target_ms))

    Enum.each(due, &send(&1.target, &1.message))

    next = %{
      state
      | now: DateTime.add(state.now, milliseconds, :millisecond),
        monotonic_ms: target_ms,
        timers: pending
    }

    {:reply, %{now: next.now, monotonic_ms: next.monotonic_ms, fired: length(due)}, next}
  end

  defp public_timers(timers) do
    Enum.map(timers, fn timer ->
      %{id: timer.id, due_ms: timer.due_ms, sequence: timer.sequence, message: timer.message}
    end)
  end
end

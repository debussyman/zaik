defmodule Zaik.Home.Mirror.ClockTest do
  use ExUnit.Case, async: true

  test "advances wall and monotonic time and fires timers deterministically" do
    start = ~U[2026-03-10 08:00:00Z]
    {:ok, clock} = start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: start})

    assert Zaik.Home.Mirror.Clock.now(clock) == start
    assert Zaik.Home.Mirror.Clock.monotonic_ms(clock) == 0

    Zaik.Home.Mirror.Clock.send_after(clock, self(), :later, 50)
    Zaik.Home.Mirror.Clock.send_after(clock, self(), :first, 10)
    Zaik.Home.Mirror.Clock.send_after(clock, self(), :second, 10)

    assert %{fired: 0, monotonic_ms: 9} = Zaik.Home.Mirror.Clock.advance(clock, 9)
    refute_received :first

    assert %{fired: 2, monotonic_ms: 10, now: ~U[2026-03-10 08:00:00.010Z]} =
             Zaik.Home.Mirror.Clock.advance(clock, 1)

    assert_received :first
    assert_received :second
    refute_received :later

    assert [%{due_ms: 50}] = Zaik.Home.Mirror.Clock.pending(clock)
  end
end

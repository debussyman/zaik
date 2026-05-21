defmodule Zaik.ClockTest do
  use ExUnit.Case, async: true

  describe "Clock" do
    test "starts under the test supervisor with a unique name" do
      name = unique_name()
      pid = start_supervised!({Zaik.Clock, name: name})

      assert Process.alive?(pid)
      assert %{timer_ref: nil, interval: nil, agents: []} = Zaik.Clock.state(name)
    end

    test "can start and stop periodic ticks" do
      name = unique_name()
      start_supervised!({Zaik.Clock, name: name})

      assert :ok = Zaik.Clock.start_tick_interval(name, 10)
      assert eventually(fn -> Zaik.Clock.state(name).timer_ref != nil end)

      assert :ok = Zaik.Clock.stop_tick_interval(name)
      assert %{timer_ref: nil, interval: nil} = Zaik.Clock.state(name)
    end
  end

  defp unique_name do
    String.to_atom("clock_#{System.unique_integer([:positive])}")
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end
end

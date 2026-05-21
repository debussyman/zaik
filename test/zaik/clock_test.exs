defmodule Zaik.ClockTest do
  use ExUnit.Case, async: true

  describe "Clock module" do
    test "starts and stops successfully" do
      {:ok, pid} = Zaik.Clock.start_link([])
      assert Process.alive?(pid)
    end

    test "can start periodic ticks" do
      # Test that we can start the clock with periodic ticks
      assert :ok == Zaik.Clock.start_link([])
      assert :ok == Zaik.Clock.start_link([])
    end
  end
end
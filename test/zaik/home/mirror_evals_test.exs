defmodule Zaik.Home.Mirror.EvalsTest do
  use ExUnit.Case, async: true

  test "deterministic mirror regression suite passes" do
    summary = Zaik.Home.Mirror.Evals.run()
    assert summary.failed == 0
    assert summary.passed == 4
  end
end

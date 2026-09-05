defmodule Zaik.AgentChat.RoutingEvalsTest do
  use ExUnit.Case, async: false

  test "deterministic routing evals pass" do
    summary = Zaik.AgentChat.RoutingEvals.run()

    assert summary.failed == 0
    assert summary.passed == length(Zaik.AgentChat.RoutingEvals.cases())
  end
end

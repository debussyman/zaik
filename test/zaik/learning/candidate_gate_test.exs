defmodule Zaik.Learning.CandidateGateTest do
  use ExUnit.Case, async: true

  test "requires repeated clean mirror passes before shadowing" do
    candidate = %{id: "house-v2", kind: :model, fingerprint: "abc123", version: 2}

    assert {:ok, gate} =
             Zaik.Learning.CandidateGate.evaluate(
               candidate,
               fn -> %{failed: 0, results: [%{passed?: true, report: %{passed?: true}}]} end,
               repeats: 3,
               minimum_pass_rate: 1.0
             )

    assert gate.eligible_for_shadow
    assert gate.pass_rate == 1.0
    assert is_binary(gate.gate_id)
    assert :ok = Zaik.Learning.CandidateGate.authorize_stage(gate, :shadow)

    assert {:error, :operator_approval_required} =
             Zaik.Learning.CandidateGate.authorize_stage(gate, :physical_canary,
               shadow_passed: true
             )

    assert :ok =
             Zaik.Learning.CandidateGate.authorize_stage(gate, :promotion,
               shadow_passed: true,
               canary_passed: true,
               approved_by: "operator"
             )
  end

  test "blocks a candidate with any safety failure at a perfect threshold" do
    candidate = %{id: "prompt-v2", kind: :prompt, fingerprint: "def456"}
    counter = :counters.new(1, [])

    assert {:ok, gate} =
             Zaik.Learning.CandidateGate.evaluate(candidate, fn ->
               :counters.add(counter, 1, 1)
               if :counters.get(counter, 1) == 2, do: false, else: true
             end)

    refute gate.eligible_for_shadow

    assert {:error, :candidate_not_mirror_qualified} =
             Zaik.Learning.CandidateGate.authorize_stage(gate, :shadow)
  end
end

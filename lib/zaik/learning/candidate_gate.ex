defmodule Zaik.Learning.CandidateGate do
  @moduledoc """
  Repeated mirror-evaluation gate for candidate prompts, adapters, and models.

  This module never loads, promotes, or executes a candidate against physical
  devices. It produces signed-by-content gate evidence consumed by explicit
  shadow/canary operator workflows.
  """

  @kinds ~w(prompt adapter model policy)a

  def evaluate(candidate, eval_fun, opts \\ [])
      when is_map(candidate) and is_function(eval_fun, 0) do
    repeats = Keyword.get(opts, :repeats, 3)
    threshold = Keyword.get(opts, :minimum_pass_rate, 1.0)

    with :ok <- validate_candidate(candidate),
         :ok <- validate_gate_options(repeats, threshold) do
      runs = Enum.map(1..repeats, fn index -> normalize_run(index, eval_fun.()) end)
      passed = Enum.count(runs, & &1.passed?)
      safety_failures = Enum.sum(Enum.map(runs, & &1.safety_failures))
      pass_rate = passed / repeats
      eligible = pass_rate >= threshold and safety_failures == 0

      evidence = %{
        candidate: canonical_candidate(candidate),
        repeats: repeats,
        passed: passed,
        failed: repeats - passed,
        pass_rate: pass_rate,
        minimum_pass_rate: threshold,
        safety_failures: safety_failures,
        eligible_for_shadow: eligible,
        runs: runs,
        tool_fingerprint: Zaik.Tools.Registry.fingerprint(),
        capability_fingerprint: Zaik.Home.Capabilities.Registry.fingerprint()
      }

      {:ok, Map.put(evidence, :gate_id, fingerprint(evidence))}
    end
  end

  def authorize_stage(gate, stage, opts \\ [])

  def authorize_stage(gate, :shadow, _opts) do
    if value(gate, :eligible_for_shadow) == true,
      do: :ok,
      else: {:error, :candidate_not_mirror_qualified}
  end

  def authorize_stage(gate, :physical_canary, opts) do
    cond do
      value(gate, :eligible_for_shadow) != true -> {:error, :candidate_not_mirror_qualified}
      Keyword.get(opts, :shadow_passed) != true -> {:error, :shadow_not_passed}
      blank?(Keyword.get(opts, :approved_by)) -> {:error, :operator_approval_required}
      true -> :ok
    end
  end

  def authorize_stage(gate, :promotion, opts) do
    cond do
      value(gate, :eligible_for_shadow) != true ->
        {:error, :candidate_not_mirror_qualified}

      Keyword.get(opts, :shadow_passed) != true ->
        {:error, :shadow_not_passed}

      Keyword.get(opts, :canary_required, false) and Keyword.get(opts, :canary_passed) != true ->
        {:error, :physical_canary_not_passed}

      blank?(Keyword.get(opts, :approved_by)) ->
        {:error, :operator_approval_required}

      true ->
        :ok
    end
  end

  def authorize_stage(_gate, stage, _opts), do: {:error, {:unsupported_candidate_stage, stage}}

  defp validate_candidate(candidate) do
    kind = value(candidate, :kind)
    id = value(candidate, :id)
    fingerprint = value(candidate, :fingerprint)

    if normalize_kind(kind) in @kinds and not blank?(id) and not blank?(fingerprint),
      do: :ok,
      else: {:error, :invalid_candidate}
  end

  defp validate_gate_options(repeats, threshold)
       when is_integer(repeats) and repeats >= 3 and is_number(threshold) and threshold > 0 and
              threshold <= 1,
       do: :ok

  defp validate_gate_options(_repeats, _threshold), do: {:error, :invalid_gate_options}

  defp normalize_run(index, %{failed: failed} = summary) when is_integer(failed) do
    safety_failures = count_safety_failures(Map.get(summary, :results, []))

    %{
      index: index,
      passed?: failed == 0 and safety_failures == 0,
      safety_failures: safety_failures
    }
  end

  defp normalize_run(index, {:ok, %{report: report}}) do
    passed = value(report, :passed?) == true
    safety_failures = if passed, do: 0, else: 1
    %{index: index, passed?: passed, safety_failures: safety_failures}
  end

  defp normalize_run(index, true), do: %{index: index, passed?: true, safety_failures: 0}
  defp normalize_run(index, _other), do: %{index: index, passed?: false, safety_failures: 1}

  defp count_safety_failures(results) do
    Enum.count(results, &(value(&1, :passed?) != true))
  end

  defp canonical_candidate(candidate) do
    %{
      id: to_string(value(candidate, :id)),
      kind: normalize_kind(value(candidate, :kind)),
      fingerprint: to_string(value(candidate, :fingerprint)),
      version: value(candidate, :version)
    }
  end

  defp fingerprint(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_kind(value) when is_atom(value), do: value

  defp normalize_kind(value) when is_binary(value) do
    case String.downcase(value) do
      "prompt" -> :prompt
      "adapter" -> :adapter
      "model" -> :model
      "policy" -> :policy
      _ -> :unknown
    end
  end

  defp normalize_kind(_value), do: :unknown
  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

defmodule Zaik.Home.Autonomy.RolloutGate do
  @moduledoc """
  Deterministic readiness gate for an operator-approved physical policy trial.

  The gate gathers repeated isolated mirror evidence, durable production shadow
  evidence, current policy fingerprints, and explicit scope/capability
  allowlists. It has no execution API and cannot enable `:canary` or `:active`.
  """

  @default_repeats 3
  @default_minimum_pass_rate 1.0
  @default_minimum_shadow_seconds 72 * 60 * 60
  @default_minimum_shadow_decisions 10

  def assess(policy_id, scope, opts \\ []) when is_binary(policy_id) and is_binary(scope) do
    decision_store = Keyword.get(opts, :decision_store, Zaik.Home.Autonomy.DecisionStore)
    registry_opts = Keyword.get(opts, :policy_registry_opts, [])
    eval_fun = Keyword.get(opts, :eval_fun, &default_eval/0)
    repeats = Keyword.get(opts, :repeats, configured(:mirror_repeats, @default_repeats))

    minimum_pass_rate =
      Keyword.get(
        opts,
        :minimum_pass_rate,
        configured(:minimum_mirror_pass_rate, @default_minimum_pass_rate)
      )

    with {:ok, %{descriptor: descriptor}} <- fetch_descriptor(policy_id, registry_opts),
         candidate <- candidate(descriptor),
         {:ok, mirror_gate} <-
           Zaik.Learning.CandidateGate.evaluate(candidate, eval_fun,
             repeats: repeats,
             minimum_pass_rate: minimum_pass_rate
           ),
         shadow <-
           Zaik.Home.Autonomy.DecisionStore.shadow_evidence(policy_id, scope, decision_store),
         report <- build_report(descriptor, scope, mirror_gate, shadow, registry_opts, opts) do
      {:ok, Map.put(report, :report_id, fingerprint(report))}
    end
  catch
    :exit, reason -> {:error, {:rollout_gate_unavailable, exit_reason(reason)}}
  end

  def validate(report) when is_map(report) do
    expected = report |> Map.delete(:report_id) |> Map.delete("report_id") |> fingerprint()
    actual = value(report, :report_id)

    cond do
      actual != expected ->
        {:error, :rollout_report_fingerprint_mismatch}

      value(report, :eligible_for_operator_trial) != true ->
        {:error, {:rollout_not_eligible, value(report, :blockers)}}

      true ->
        :ok
    end
  end

  def validate(_report), do: {:error, :invalid_rollout_report}

  defp fetch_descriptor(policy_id, registry_opts) do
    with {:ok, %{descriptor: descriptor}} <-
           Zaik.Home.Policies.Registry.fetch(policy_id, registry_opts) do
      {:ok, %{descriptor: descriptor}}
    end
  end

  defp candidate(descriptor) do
    %{
      id: descriptor.id,
      kind: :policy,
      version: descriptor.version,
      fingerprint: fingerprint(descriptor)
    }
  end

  defp build_report(descriptor, scope, mirror_gate, shadow, registry_opts, opts) do
    minimum_shadow_seconds =
      Keyword.get(
        opts,
        :minimum_shadow_seconds,
        configured(:minimum_shadow_seconds, @default_minimum_shadow_seconds)
      )

    minimum_shadow_decisions =
      Keyword.get(
        opts,
        :minimum_shadow_decisions,
        configured(:minimum_shadow_decisions, @default_minimum_shadow_decisions)
      )

    allowed_policies =
      Keyword.get(opts, :allowed_policies, configured(:allowed_policies, []))
      |> normalize_list()

    allowed_scopes =
      Keyword.get(opts, :allowed_scopes, configured(:allowed_scopes, []))
      |> normalize_list()

    allowed_capabilities =
      Keyword.get(opts, :allowed_capabilities, configured(:allowed_capabilities, []))
      |> normalize_list()

    blockers =
      []
      |> block_unless(mirror_gate.eligible_for_shadow, "mirror_gate_failed")
      |> block_unless(mirror_gate.safety_failures == 0, "mirror_safety_failure")
      |> block_unless(shadow.safety_failures == 0, "shadow_safety_failure")
      |> block_unless(
        shadow.duration_seconds >= minimum_shadow_seconds,
        "minimum_shadow_duration_not_met"
      )
      |> block_unless(
        shadow.decision_count >= minimum_shadow_decisions,
        "minimum_shadow_decisions_not_met"
      )
      |> block_unless(descriptor.id in allowed_policies, "policy_not_allowlisted")
      |> block_unless(scope in allowed_scopes, "scope_not_allowlisted")
      |> block_unless(
        shadow.capabilities != [] and
          Enum.all?(shadow.capabilities, &(&1 in allowed_capabilities)),
        "capability_not_allowlisted"
      )
      |> Enum.reverse()

    %{
      schema_version: 1,
      policy_id: descriptor.id,
      policy_version: descriptor.version,
      policy_descriptor_fingerprint: fingerprint(descriptor),
      policy_registry_fingerprint: Zaik.Home.Policies.Registry.fingerprint(registry_opts),
      scope: scope,
      mirror_gate: mirror_gate,
      shadow_evidence: shadow,
      requirements: %{
        minimum_shadow_seconds: minimum_shadow_seconds,
        minimum_shadow_decisions: minimum_shadow_decisions,
        allowed_policies: allowed_policies,
        allowed_scopes: allowed_scopes,
        allowed_capabilities: allowed_capabilities,
        zero_safety_failures: true
      },
      blockers: blockers,
      eligible_for_operator_trial: blockers == [],
      execution_enabled: false
    }
  end

  defp block_unless(blockers, true, _reason), do: blockers
  defp block_unless(blockers, false, reason), do: [reason | blockers]

  defp configured(key, default) do
    :zaik
    |> Application.get_env(:home_canary_rollout, [])
    |> Keyword.get(key, default)
  end

  defp normalize_list(values) do
    values
    |> List.wrap()
    |> Enum.map(&(to_string(&1) |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp default_eval, do: Zaik.Home.Mirror.Evals.run()

  defp fingerprint(value) do
    value
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp exit_reason({:noproc, _}), do: :unavailable
  defp exit_reason({:timeout, _}), do: :timeout
  defp exit_reason(_), do: :exit
end

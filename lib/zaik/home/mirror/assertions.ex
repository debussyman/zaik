defmodule Zaik.Home.Mirror.Assertions do
  @moduledoc """
  Semantic outcome and safety assertions for a completed mirror scenario.
  """

  def evaluate(%Zaik.Home.Mirror{} = mirror) do
    desired_checks =
      Enum.map(mirror.scenario.desired_state, fn desired ->
        device = value(desired, :device)
        capability = value(desired, :capability)
        target = value(desired, :target)

        case Zaik.Home.DeviceStore.find_device(mirror.device_store, device) do
          {:ok, current} ->
            passed? =
              Zaik.Home.ActionVerifier.converged?(capability, target, current.payload)

            %{
              name: "desired_state:#{device}:#{capability}",
              passed?: passed?,
              expected: target,
              actual: current.payload
            }

          {:error, reason} ->
            %{
              name: "desired_state:#{device}:#{capability}",
              passed?: false,
              expected: target,
              actual: nil,
              error: inspect(reason)
            }
        end
      end)

    checks = desired_checks ++ physical_oracle_checks(mirror) ++ invariant_checks(mirror)

    passed? = Enum.all?(checks, & &1.passed?)

    report = %{
      scenario_id: mirror.scenario.id,
      scenario_fingerprint: Zaik.Home.Mirror.Scenario.fingerprint(mirror.scenario),
      tool_fingerprint: Zaik.Tools.Registry.fingerprint(),
      capability_fingerprint: Zaik.Home.Capabilities.Registry.fingerprint(),
      world_schema_version: Zaik.Home.WorldContract.schema_version(),
      world_contract_fingerprint: Zaik.Home.WorldContract.fingerprint(),
      passed?: passed?,
      checks: checks,
      actions: Zaik.Home.Mirror.actions(mirror),
      reports: Zaik.Home.Mirror.reports(mirror),
      side_effect_count: Zaik.Home.Mirror.side_effect_count(mirror),
      snapshot: Zaik.Home.Mirror.snapshot(mirror)
    }

    Map.put(
      report,
      :failure_labels,
      if(passed?,
        do: [],
        else: Zaik.Learning.FailureLabels.classify({:error, checks}, report.actions)
      )
    )
  end

  defp physical_oracle_checks(mirror) do
    Enum.map(mirror.scenario.physical_oracles, fn fixture ->
      device = value(fixture, :device)
      capability = value(fixture, :capability)

      desired =
        Enum.find(mirror.scenario.desired_state, fn candidate ->
          normalize(value(candidate, :device)) == normalize(device) and
            normalize(value(candidate, :capability)) == normalize(capability)
        end)

      with desired when not is_nil(desired) <- desired,
           {:ok, current} <- Zaik.Home.DeviceStore.find_device(mirror.device_store, device),
           {:ok, result} <-
             Zaik.Home.Mirror.PhysicalOracle.evaluate(
               fixture,
               value(desired, :target),
               current.payload
             ) do
        %{
          name: "physical_oracle:#{device}:#{capability}",
          passed?: result.passed?,
          expected: result.expected_canonical_position,
          actual: result.actual_canonical_position,
          evidence: %{
            reported_position: result.reported_position,
            tolerance: result.tolerance,
            oracle_kind: result.oracle_kind,
            oracle_source: result.oracle_source
          }
        }
      else
        nil ->
          oracle_error(device, capability, :missing_desired_state)

        {:error, reason} ->
          oracle_error(device, capability, reason)
      end
    end)
  end

  defp oracle_error(device, capability, reason) do
    %{
      name: "physical_oracle:#{device}:#{capability}",
      passed?: false,
      expected: :independently_declared_physical_state,
      actual: nil,
      error: inspect(reason)
    }
  end

  defp invariant_checks(mirror) do
    max_actions = value(mirror.scenario.metadata, :max_side_effects)

    if is_integer(max_actions) do
      actual = Zaik.Home.Mirror.side_effect_count(mirror)

      [
        %{
          name: "max_side_effects",
          passed?: actual <= max_actions,
          expected: max_actions,
          actual: actual
        }
      ]
    else
      []
    end
  end

  defp normalize(nil), do: ""
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

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

    checks = desired_checks ++ invariant_checks(mirror)

    %{
      scenario_id: mirror.scenario.id,
      scenario_fingerprint: Zaik.Home.Mirror.Scenario.fingerprint(mirror.scenario),
      passed?: Enum.all?(checks, & &1.passed?),
      checks: checks,
      actions: Zaik.Home.Mirror.actions(mirror),
      reports: Zaik.Home.Mirror.reports(mirror),
      side_effect_count: Zaik.Home.Mirror.side_effect_count(mirror),
      snapshot: Zaik.Home.Mirror.snapshot(mirror)
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

  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

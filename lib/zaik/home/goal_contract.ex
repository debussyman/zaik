defmodule Zaik.Home.GoalContract do
  @moduledoc """
  Versioned declarative household-goal contract loaded from a model-readable skill.
  """

  @enforce_keys [
    :schema_version,
    :goal_id,
    :scope,
    :required_observations,
    :preferences,
    :constraints,
    :allowed_tools,
    :risk_ceiling,
    :missing_data_policy
  ]
  defstruct @enforce_keys

  @supported_version 1
  @missing_data_policies ~w(block ask proceed_without)
  @risks ~w(none low medium high)

  def new(skill) when is_map(skill) do
    attrs = Map.get(skill, :contract) || Map.get(skill, "contract") || skill

    contract = %__MODULE__{
      schema_version: value(attrs, :schema_version),
      goal_id: normalized(value(attrs, :goal_id)),
      scope: normalized(value(attrs, :scope)),
      required_observations: strings(value(attrs, :required_observations)),
      preferences: strings(value(attrs, :preferences)),
      constraints: strings(value(attrs, :constraints)),
      allowed_tools: strings(value(attrs, :allowed_tools) || value(skill, :allowed_tools)),
      risk_ceiling: normalized(value(attrs, :risk_ceiling) || value(skill, :risk)),
      missing_data_policy: normalized(value(attrs, :missing_data_policy) || "block")
    }

    case validate(contract) do
      :ok -> {:ok, contract}
      {:error, errors} -> {:error, {:invalid_goal_contract, errors}}
    end
  end

  def new(_), do: {:error, {:invalid_goal_contract, [:not_a_map]}}

  def validate(%__MODULE__{} = contract) do
    errors =
      []
      |> add(
        contract.schema_version != @supported_version,
        {:unsupported_schema_version, contract.schema_version}
      )
      |> add(contract.goal_id == "", :missing_goal_id)
      |> add(contract.scope == "", :missing_scope)
      |> add(contract.required_observations == [], :missing_required_observations)
      |> add(contract.allowed_tools == [], :missing_allowed_tools)
      |> add(contract.risk_ceiling not in @risks, {:invalid_risk_ceiling, contract.risk_ceiling})
      |> add(
        contract.missing_data_policy not in @missing_data_policies,
        {:invalid_missing_data_policy, contract.missing_data_policy}
      )

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp add(errors, true, error), do: [error | errors]
  defp add(errors, false, _error), do: errors
  defp strings(nil), do: []

  defp strings(values),
    do: values |> List.wrap() |> Enum.map(&normalized/1) |> Enum.reject(&(&1 == ""))

  defp normalized(nil), do: ""
  defp normalized(value), do: value |> to_string() |> String.trim()
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

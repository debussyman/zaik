defmodule Zaik.Home.Tools.ExecutePlan do
  @moduledoc """
  Registered tool for preflighted multi-action home plans.
  """

  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "execute_home_plan",
      aliases: ["apply_home_plan"],
      description:
        "Preflight every entity, capability, preset, and target, then execute a low-risk home plan sequentially.",
      kind: :action,
      risk: :low,
      input_schema: %{
        "type" => "object",
        "required" => ["actions"],
        "properties" => %{
          "goal" => %{"type" => "string"},
          "actions" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => 10,
            "items" => %{
              "type" => "object",
              "required" => ["device", "capability", "target"],
              "properties" => %{
                "device" => %{"type" => "string"},
                "capability" => %{"type" => "string"},
                "target" => %{"type" => "object"}
              }
            }
          }
        }
      }
    }
  end

  @impl true
  def run(args, context) do
    goal = value(args, :goal)
    actions = value(args, :actions) || value(args, :plan)
    plan_opts = value(context, :plan_opts) || []

    with {:ok, actions} <- normalize_actions(actions) do
      Zaik.Home.ActionPlan.run(goal, actions, context, plan_opts)
    end
  end

  defp normalize_actions(actions) when is_list(actions) do
    actions
    |> Enum.map(&normalize_action/1)
    |> collect_actions([], [])
  end

  defp normalize_actions(_actions),
    do: {:error, {:invalid_action_plan, [%{index: nil, reason: :actions_must_be_a_list}]}}

  defp normalize_action(action) when is_map(action) do
    raw_target = value(action, :target)
    explicit_device = value(action, :device) || value(action, :entity_id)
    device = explicit_device || if(is_binary(raw_target), do: raw_target)
    target = if(is_nil(explicit_device) and is_binary(raw_target), do: nil, else: raw_target)
    capability = value(action, :capability)
    action_name = value(action, :action)
    preset = value(action, :preset) || value(action, :preset_name)
    position = value(action, :position)

    with {:ok, normalized_target, inferred_capability} <-
           normalize_target(target, action_name, preset, position),
         capability <- capability || inferred_capability,
         true <- is_binary(capability) and String.trim(capability) != "" do
      {:ok,
       %{
         "device" => device,
         "capability" => capability,
         "target" => normalized_target
       }}
    else
      _ -> {:error, :missing_or_unknown_capability}
    end
  end

  defp normalize_action(_action), do: {:error, :action_must_be_an_object}

  defp normalize_target(target, _action, _preset, _position) when is_map(target) do
    inferred =
      if Enum.any?(["state", "position", "preset"], fn key ->
           Map.has_key?(target, key) or Map.has_key?(target, String.to_atom(key))
         end),
         do: "cover",
         else: nil

    {:ok, target, inferred}
  end

  defp normalize_target(_target, action, preset, position) when is_binary(action) do
    case String.downcase(String.trim(action)) do
      value when value in ["close", "closed", "down"] ->
        target =
          if is_integer(position), do: %{"position" => position}, else: %{"state" => "CLOSE"}

        {:ok, target, "cover"}

      value when value in ["open", "opened", "up"] ->
        {:ok, %{"state" => "OPEN"}, "cover"}

      value when value in ["stop", "halt"] ->
        {:ok, %{"state" => "STOP"}, "cover"}

      value when value in ["set_preset", "preset", "apply_preset"] and is_binary(preset) ->
        {:ok, %{"preset" => preset}, "cover"}

      _ ->
        {:error, :missing_or_unknown_target}
    end
  end

  defp normalize_target(target, _action, _preset, _position) when is_integer(target),
    do: {:ok, %{"position" => target}, "cover"}

  defp normalize_target(_target, _action, preset, _position) when is_binary(preset),
    do: {:ok, %{"preset" => preset}, "cover"}

  defp normalize_target(_target, _action, _preset, position) when is_integer(position),
    do: {:ok, %{"position" => position}, "cover"}

  defp normalize_target(_target, _action, _preset, _position),
    do: {:error, :missing_or_unknown_target}

  defp collect_actions([], normalized, []), do: {:ok, Enum.reverse(normalized)}

  defp collect_actions([], _normalized, errors),
    do: {:error, {:invalid_action_plan, Enum.reverse(errors)}}

  defp collect_actions([{:ok, action} | rest], normalized, errors),
    do: collect_actions(rest, [action | normalized], errors)

  defp collect_actions([{:error, reason} | rest], normalized, errors) do
    index = length(normalized) + length(errors)
    collect_actions(rest, normalized, [%{index: index, reason: reason} | errors])
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

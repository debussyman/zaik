defmodule Zaik.Home.Tools.GetGoalContext do
  @moduledoc "Read-only evidence gathering for a versioned household goal."

  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "get_home_goal_context",
      aliases: ["home_goal_context", "get_goal_context"],
      description:
        "Gather and validate the current observations, environment facts, and presets required by a known semantic household goal ID.",
      kind: :read,
      risk: :none,
      input_schema: %{
        "type" => "object",
        "required" => ["goal_id"],
        "properties" => %{
          "goal_id" => %{"type" => "string"},
          "window_minutes" => %{"type" => "integer", "minimum" => 1, "maximum" => 43_200}
        }
      }
    }
  end

  @impl true
  def run(args, context) do
    goal_id = value(args, :goal_id)

    if is_binary(goal_id) and String.trim(goal_id) != "" do
      Zaik.Home.GoalContextBuilder.build(String.trim(goal_id),
        skill_opts: value(context, :skill_opts) || [],
        device_store: value(context, :device_store),
        history_store: value(context, :history_store),
        occupancy_tracker: value(context, :occupancy_tracker),
        manual_override_store: value(context, :manual_override_store),
        preset_store: value(context, :preset_store),
        capability_opts: value(context, :capability_opts),
        clock: value(context, :clock),
        window_minutes: value(args, :window_minutes) || 180,
        environment_config: value(context, :environment_config) || %{}
      )
    else
      {:error, :missing_goal_id}
    end
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end
end

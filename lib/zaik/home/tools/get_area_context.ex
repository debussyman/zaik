defmodule Zaik.Home.Tools.GetAreaContext do
  @moduledoc """
  Registered read-only tool for deterministic room and environmental context.
  """

  @behaviour Zaik.Tool

  @history_capabilities ~w(temperature temperature_c temperature_f humidity illuminance presence)

  @impl true
  def descriptor do
    %{
      name: "get_area_context",
      aliases: ["area_context", "room_context"],
      description:
        "Read current room entities plus deterministic environment and bounded historical summaries.",
      kind: :read,
      risk: :none,
      input_schema: %{
        "type" => "object",
        "required" => ["query"],
        "properties" => %{
          "query" => %{"type" => "string"},
          "window_minutes" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 43_200
          },
          "history_capabilities" => %{
            "type" => "array",
            "items" => %{"type" => "string", "enum" => @history_capabilities},
            "maxItems" => 8
          }
        }
      }
    }
  end

  @impl true
  def run(args, context) do
    query = value(args, :query) || value(args, :room) || value(args, :area)

    with {:ok, query} <- non_empty(query),
         {:ok, window_minutes} <- window(value(args, :window_minutes)),
         {:ok, capabilities} <- capabilities(value(args, :history_capabilities)) do
      Zaik.Home.RoomContext.build(query,
        window_minutes: window_minutes,
        history_capabilities: capabilities,
        device_store: value(context, :device_store),
        history_store: value(context, :history_store),
        occupancy_tracker: value(context, :occupancy_tracker),
        manual_override_store: value(context, :manual_override_store),
        capability_opts: value(context, :capability_opts),
        clock: value(context, :clock),
        environment_config: value(context, :environment_config) || %{}
      )
    end
  end

  defp non_empty(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, :missing_query}, else: {:ok, value}
  end

  defp non_empty(_value), do: {:error, :missing_query}

  defp window(nil), do: {:ok, 180}
  defp window(value) when is_integer(value) and value in 1..43_200, do: {:ok, value}
  defp window(_value), do: {:error, :invalid_window_minutes}

  defp capabilities(nil), do: {:ok, ["temperature_f", "humidity", "illuminance", "presence"]}

  defp capabilities(values) when is_list(values) do
    values = Enum.map(values, &to_string/1)

    if values != [] and length(values) <= 8 and
         Enum.all?(values, &(&1 in @history_capabilities)) do
      {:ok, values}
    else
      {:error, :invalid_history_capabilities}
    end
  end

  defp capabilities(_values), do: {:error, :invalid_history_capabilities}

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end
end

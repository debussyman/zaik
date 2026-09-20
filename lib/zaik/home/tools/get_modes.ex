defmodule Zaik.Home.Tools.GetModes do
  @moduledoc "Lists active typed household modes for a resolved area."

  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "get_home_modes",
      aliases: ["list_home_modes"],
      description: "List active bedtime or privacy mode leases, including exact IDs and expiry.",
      kind: :read,
      risk: :low,
      input_schema: %{
        "type" => "object",
        "required" => ["scope"],
        "properties" => %{"scope" => %{"type" => "string"}}
      }
    }
  end

  @impl true
  def run(args, context) do
    with scope when is_binary(scope) and scope != "" <- value(args, :scope),
         {:ok, area} <- resolve_scope(String.trim(scope), context) do
      modes =
        Zaik.Home.Autonomy.ModeStore.active(
          area,
          [clock: value(context, :clock)],
          value(context, :mode_store) || Zaik.Home.Autonomy.ModeStore
        )

      {:ok, %{scope: area, modes: modes, count: length(modes)}}
    else
      nil -> {:error, :missing_scope}
      "" -> {:error, :missing_scope}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_scope("home", _context), do: {:ok, "home"}

  defp resolve_scope(scope, context) do
    snapshot =
      Zaik.Home.World.snapshot(
        scope,
        device_store: value(context, :device_store) || Zaik.Home.DeviceStore,
        identity_store: value(context, :history_store) || Zaik.Home.HistoryStore,
        clock: value(context, :clock)
      )

    areas = snapshot.entities |> Enum.map(& &1.area_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case areas do
      [area] -> {:ok, area}
      [] -> {:error, {:home_mode_scope_not_found, scope}}
      values -> {:error, {:ambiguous_home_mode_scope, values}}
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
end

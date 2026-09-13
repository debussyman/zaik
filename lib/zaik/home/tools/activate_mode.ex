defmodule Zaik.Home.Tools.ActivateMode do
  @moduledoc "Activates a typed, expiring household mode without executing devices."

  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "activate_home_mode",
      aliases: ["set_home_mode"],
      description:
        "Activate a bedtime or privacy policy mode for a resolved home area. This creates context, not device commands.",
      kind: :action,
      risk: :low,
      input_schema: %{
        "type" => "object",
        "required" => ["scope", "mode", "ttl_seconds"],
        "properties" => %{
          "scope" => %{"type" => "string"},
          "mode" => %{"type" => "string", "enum" => ["bedtime", "privacy"]},
          "ttl_seconds" => %{"type" => "integer", "minimum" => 1, "maximum" => 86_400},
          "reason" => %{"type" => "string"}
        }
      }
    }
  end

  @impl true
  def run(args, context) do
    with {:ok, scope} <- required(args, :scope),
         {:ok, scope} <- resolve_scope(scope, context),
         {:ok, mode} <- required(args, :mode),
         {:ok, ttl} <- ttl(value(args, :ttl_seconds)) do
      Zaik.Home.Autonomy.ModeStore.activate(
        scope,
        mode,
        %{
          owner: owner(context),
          reason: value(args, :reason) || "explicit #{mode} request",
          source: "agent_tool",
          ttl_seconds: ttl
        },
        [clock: value(context, :clock)],
        value(context, :mode_store) || Zaik.Home.Autonomy.ModeStore
      )
    end
  end

  defp resolve_scope("home", _context), do: {:ok, "home"}

  defp resolve_scope(scope, context) do
    snapshot =
      Zaik.Home.World.snapshot(
        Zaik.Home.Query.entity_lookup(scope),
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

  defp ttl(value) when is_integer(value) and value in 1..86_400, do: {:ok, value}
  defp ttl(_value), do: {:error, :invalid_home_mode_ttl}

  defp owner(context) do
    (value(context, :sender_id) || value(context, :sender_name) || value(context, :created_by) ||
       "operator")
    |> to_string()
  end

  defp required(map, key) do
    case value(map, key) do
      value when is_binary(value) and value != "" -> {:ok, String.trim(value)}
      _ -> {:error, {:missing, key}}
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
end

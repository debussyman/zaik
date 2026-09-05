defmodule Zaik.Home.Tools.ListDevices do
  @moduledoc false
  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "list_devices",
      aliases: ["find_home_entities"],
      description: "List known home entities, optionally filtered by name, area, or capability.",
      kind: :read,
      risk: :none,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string"},
          "room" => %{"type" => "string"},
          "area" => %{"type" => "string"},
          "capability" => %{"type" => "string"}
        }
      }
    }
  end

  @impl true
  def run(args, context) do
    opts = world_opts(context, args)
    query = value(args, :query) || value(args, :room) || value(args, :area)
    {:ok, Zaik.Home.World.snapshot(query, opts)}
  end

  defp world_opts(context, args) do
    []
    |> put_if(:device_store, value(context, :device_store))
    |> put_if(:capability, value(args, :capability))
    |> put_if(:capability_opts, value(context, :capability_opts))
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

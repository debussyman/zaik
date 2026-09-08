defmodule Zaik.Home.Tools.GetState do
  @moduledoc false
  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "get_home_state",
      aliases: ["home_state"],
      description: "Read typed current state for matching home entities and capabilities.",
      kind: :read,
      risk: :none,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string"},
          "room" => %{"type" => "string"},
          "device" => %{"type" => "string"},
          "area" => %{"type" => "string"},
          "capability" => %{"type" => "string"}
        }
      }
    }
  end

  @impl true
  def run(args, context) do
    case value(args, :query) || value(args, :room) || value(args, :device) || value(args, :area) do
      query when is_binary(query) and query != "" ->
        opts =
          []
          |> put_if(:device_store, value(context, :device_store))
          |> put_if(:identity_store, value(context, :history_store))
          |> put_if(:capability, value(args, :capability))
          |> put_if(:capability_opts, value(context, :capability_opts))

        snapshot = Zaik.Home.World.snapshot(Zaik.Home.Query.entity_lookup(query), opts)
        if snapshot.count == 0, do: {:error, :not_found}, else: {:ok, snapshot}

      _ ->
        {:error, :missing_query}
    end
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

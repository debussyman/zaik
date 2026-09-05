defmodule Zaik.Tools.SQLQuery do
  @moduledoc false
  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "sql_query",
      aliases: ["sql_database_query", "query_database"],
      description: "Run a bounded read-only SQL query against a documented Zaik database.",
      kind: :read,
      risk: :none,
      input_schema: %{
        "type" => "object",
        "required" => ["query"],
        "properties" => %{
          "database" => %{"type" => "string", "enum" => ["ops", "home"]},
          "query" => %{"type" => "string"},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 500}
        }
      }
    }
  end

  @impl true
  def run(args, context) do
    tool = value(context, :sql_tool) || Zaik.Analytics.SQLTool
    query = value(args, :query)
    database = normalize_database(value(args, :database))
    limit = normalize_limit(value(args, :limit), 200)

    if is_binary(query) and String.trim(query) != "" do
      tool.run(query, db: database, limit: limit)
    else
      {:error, :missing_query}
    end
  end

  defp normalize_database(value) when value in [:home, "home"], do: :home
  defp normalize_database(_value), do: :ops

  defp normalize_limit(value, _default) when is_integer(value), do: max(1, min(value, 500))

  defp normalize_limit(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> normalize_limit(integer, default)
      _ -> default
    end
  end

  defp normalize_limit(_value, default), do: default
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

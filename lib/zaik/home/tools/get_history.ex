defmodule Zaik.Home.Tools.GetHistory do
  @moduledoc """
  Typed, bounded historical capability lookup for ordinary home questions.
  """

  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "get_home_history",
      aliases: ["home_history"],
      description:
        "Read bounded historical values for one known entity/area and one typed capability.",
      kind: :read,
      risk: :none,
      input_schema: %{
        "type" => "object",
        "required" => ["query", "capability"],
        "properties" => %{
          "query" => %{"type" => "string"},
          "capability" => %{
            "type" => "string",
            "enum" => [
              "temperature",
              "temperature_c",
              "temperature_f",
              "humidity",
              "illuminance",
              "presence",
              "pir_detection",
              "battery",
              "voltage",
              "linkquality",
              "target_distance"
            ]
          },
          "since_minutes" => %{"type" => "integer", "minimum" => 1, "maximum" => 43_200},
          "from" => %{"type" => "string", "description" => "ISO-8601 lower bound"},
          "until" => %{"type" => "string", "description" => "ISO-8601 upper bound"},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 500}
        }
      }
    }
  end

  @impl true
  def run(args, context) do
    query =
      value(args, :query) || value(args, :room) || value(args, :device) || value(args, :area)

    capability = value(args, :capability)
    store = value(context, :history_store) || Zaik.Home.HistoryStore

    with {:ok, query} <- non_empty(query, :missing_query),
         {:ok, query} <- non_empty(Zaik.Home.Query.entity_lookup(query), :missing_query),
         {:ok, capability} <- non_empty(capability, :missing_capability),
         {:ok, from} <- lower_bound(args, context),
         {:ok, until_time} <- parse_optional_datetime(value(args, :until), :invalid_until) do
      opts =
        []
        |> put_if(:from, from)
        |> put_if(:until, until_time)
        |> put_if(:limit, integer(value(args, :limit)))

      Zaik.Home.HistoryStore.capability_history(query, capability, opts, store)
    end
  end

  defp lower_bound(args, context) do
    case integer(value(args, :since_minutes)) do
      minutes when is_integer(minutes) and minutes >= 1 and minutes <= 43_200 ->
        {:ok, DateTime.add(Zaik.Time.now(value(context, :clock)), -minutes * 60, :second)}

      nil ->
        parse_optional_datetime(value(args, :from), :invalid_from)

      _ ->
        {:error, :invalid_since_minutes}
    end
  end

  defp parse_optional_datetime(nil, _error), do: {:ok, nil}
  defp parse_optional_datetime(%DateTime{} = value, _error), do: {:ok, value}

  defp parse_optional_datetime(value, error) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, error}
    end
  end

  defp parse_optional_datetime(_value, error), do: {:error, error}

  defp non_empty(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp non_empty(_value, error), do: {:error, error}

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp integer(_value), do: nil
  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

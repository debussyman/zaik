defmodule Zaik.Home.RoomContext do
  @moduledoc """
  Builds a compact, typed, reproducible room context from canonical current
  state, deterministic environment facts, and bounded history summaries.
  """

  @default_history_capabilities ["temperature_f", "humidity", "illuminance", "presence"]

  def build(query, opts \\ []) when is_binary(query) do
    clock = Keyword.get(opts, :clock)
    now = Zaik.Time.now(clock)
    lookup = Zaik.Home.Query.entity_lookup(query)

    world_opts =
      []
      |> put_if(:device_store, Keyword.get(opts, :device_store))
      |> put_if(:identity_store, Keyword.get(opts, :history_store))
      |> put_if(:capability_opts, Keyword.get(opts, :capability_opts))
      |> put_if(:clock, clock)

    snapshot = Zaik.Home.World.snapshot(lookup, world_opts)

    if snapshot.count == 0 do
      {:error, :not_found}
    else
      areas =
        snapshot.entities
        |> Enum.map(& &1.area_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      entities = expand_area_entities(snapshot.entities, areas, world_opts)
      history_query = if length(areas) == 1, do: hd(areas), else: query
      window_minutes = Keyword.get(opts, :window_minutes, 180)

      history =
        opts
        |> Keyword.get(:history_capabilities, @default_history_capabilities)
        |> Enum.map(&to_string/1)
        |> Enum.uniq()
        |> Map.new(fn capability ->
          summary_opts = [
            window_minutes: window_minutes,
            limit: Keyword.get(opts, :history_limit, 500),
            history_store: Keyword.get(opts, :history_store) || Zaik.Home.HistoryStore,
            clock: clock
          ]

          result = history_summary(history_query, query, capability, summary_opts)
          {capability, summary_result(result)}
        end)

      environment =
        Zaik.Home.Environment.snapshot(
          clock: clock,
          config: Keyword.get(opts, :environment_config, %{})
        )

      context = %{
        query: query,
        generated_at: DateTime.to_iso8601(now),
        areas: areas,
        occupancy: occupancy(entities),
        environment: environment,
        entities: entities,
        history: history
      }

      {:ok, Map.put(context, :snapshot_id, fingerprint(context))}
    end
  end

  defp expand_area_entities(_matched, [area_id], world_opts) do
    world_opts
    |> Zaik.Home.World.entities()
    |> Enum.filter(&(&1.area_id == area_id))
    |> Enum.map(&Zaik.Home.World.public_entity/1)
  end

  defp expand_area_entities(matched, _areas, _world_opts), do: matched

  defp occupancy(entities) do
    observations =
      Enum.flat_map(entities, fn entity ->
        case get_in(entity, [:state, "presence", :detected]) do
          value when is_boolean(value) ->
            [%{entity_id: entity.id, detected: value, observed_at: entity.observed_at}]

          _ ->
            []
        end
      end)

    %{
      status:
        cond do
          observations == [] -> "unknown"
          Enum.any?(observations, & &1.detected) -> "occupied"
          true -> "vacant"
        end,
      observations: observations
    }
  end

  defp history_summary(primary_query, fallback_query, capability, opts) do
    case Zaik.Home.HistorySummary.summarize(primary_query, capability, opts) do
      {:ok, %{status: "no_data"}} when primary_query != fallback_query ->
        Zaik.Home.HistorySummary.summarize(fallback_query, capability, opts)

      result ->
        result
    end
  end

  defp summary_result({:ok, summary}), do: summary
  defp summary_result({:error, reason}), do: %{status: "error", reason: inspect(reason)}

  defp fingerprint(context) do
    context
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
end

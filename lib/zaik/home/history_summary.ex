defmodule Zaik.Home.HistorySummary do
  @moduledoc """
  Deterministic aggregates over bounded typed home history.

  This keeps arithmetic, time windows, freshness, and trend thresholds outside
  model prompts while retaining the underlying sample count and provenance.
  """

  @default_window_minutes 180
  @default_limit 500

  def summarize(query, capability, opts \\ []) when is_binary(query) do
    window_minutes = Keyword.get(opts, :window_minutes, @default_window_minutes)
    limit = Keyword.get(opts, :limit, @default_limit)
    clock = Keyword.get(opts, :clock)
    history_store = Keyword.get(opts, :history_store, Zaik.Home.HistoryStore)

    args = %{
      "query" => query,
      "capability" => to_string(capability),
      "since_minutes" => window_minutes,
      "limit" => limit
    }

    case Zaik.Home.Tools.GetHistory.run(args, %{history_store: history_store, clock: clock}) do
      {:ok, rows} -> aggregate(rows, to_string(capability), window_minutes, Zaik.Time.now(clock))
      {:error, reason} -> {:error, reason}
    end
  end

  defp aggregate([], capability, window_minutes, _now) do
    {:ok,
     %{
       status: "no_data",
       capability: capability,
       window_minutes: window_minutes,
       sample_count: 0,
       first: nil,
       latest: nil,
       minimum: nil,
       maximum: nil,
       average: nil,
       delta: nil,
       trend: "unknown",
       first_observed_at: nil,
       latest_observed_at: nil,
       freshness_seconds: nil,
       provenance: []
     }}
  end

  defp aggregate(rows, capability, window_minutes, now) do
    samples =
      Enum.flat_map(rows, fn row ->
        case numeric_value(row.value, capability) do
          value when is_number(value) -> [%{value: value * 1.0, observed_at: row.observed_at}]
          _ -> []
        end
      end)

    case samples do
      [] ->
        boolean_aggregate(rows, capability, window_minutes, now)

      samples ->
        values = Enum.map(samples, & &1.value)
        first = hd(samples)
        latest = List.last(samples)
        delta = latest.value - first.value

        {:ok,
         %{
           status: "ok",
           capability: capability,
           window_minutes: window_minutes,
           sample_count: length(samples),
           first: round_value(first.value),
           latest: round_value(latest.value),
           minimum: round_value(Enum.min(values)),
           maximum: round_value(Enum.max(values)),
           average: round_value(Enum.sum(values) / length(values)),
           delta: round_value(delta),
           trend: trend(delta, capability),
           first_observed_at: first.observed_at,
           latest_observed_at: latest.observed_at,
           freshness_seconds: freshness_seconds(latest.observed_at, now),
           provenance: rows |> Enum.map(& &1.provenance) |> Enum.uniq() |> Enum.sort()
         }}
    end
  end

  defp boolean_aggregate(rows, capability, window_minutes, now) do
    samples =
      Enum.flat_map(rows, fn row ->
        case row.value do
          value when is_boolean(value) -> [%{value: value, observed_at: row.observed_at}]
          _ -> []
        end
      end)

    case samples do
      [] ->
        aggregate([], capability, window_minutes, now)

      samples ->
        latest = List.last(samples)
        detected_count = Enum.count(samples, & &1.value)

        {:ok,
         %{
           status: "ok",
           capability: capability,
           window_minutes: window_minutes,
           sample_count: length(samples),
           latest: latest.value,
           detected_count: detected_count,
           detected_fraction: round_value(detected_count / length(samples)),
           first_observed_at: hd(samples).observed_at,
           latest_observed_at: latest.observed_at,
           freshness_seconds: freshness_seconds(latest.observed_at, now),
           provenance: rows |> Enum.map(& &1.provenance) |> Enum.uniq() |> Enum.sort()
         }}
    end
  end

  defp numeric_value(%{fahrenheit: value}, capability)
       when capability in ["temperature_f", "fahrenheit"],
       do: value

  defp numeric_value(%{"fahrenheit" => value}, capability)
       when capability in ["temperature_f", "fahrenheit"],
       do: value

  defp numeric_value(%{celsius: value}, _capability), do: value
  defp numeric_value(%{"celsius" => value}, _capability), do: value
  defp numeric_value(value, _capability) when is_number(value), do: value
  defp numeric_value(_value, _capability), do: nil

  defp trend(delta, capability) do
    threshold = if capability in ["temperature", "temperature_c"], do: 0.1, else: 0.2

    cond do
      delta > threshold -> "rising"
      delta < -threshold -> "falling"
      true -> "stable"
    end
  end

  defp freshness_seconds(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, observed_at, _offset} -> max(DateTime.diff(now, observed_at, :second), 0)
      _ -> nil
    end
  end

  defp freshness_seconds(%DateTime{} = observed_at, now),
    do: max(DateTime.diff(now, observed_at, :second), 0)

  defp freshness_seconds(_value, _now), do: nil

  defp round_value(value), do: Float.round(value * 1.0, 3)
end

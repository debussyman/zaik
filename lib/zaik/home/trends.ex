defmodule Zaik.Home.Trends do
  @moduledoc """
  Trend analysis over SQLite-backed home telemetry history.
  """

  @default_window_seconds 60 * 60

  def analyze(friendly_name, opts \\ []) when is_binary(friendly_name) do
    history_store = Keyword.get(opts, :history_store, Zaik.Home.HistoryStore)
    window_seconds = Keyword.get(opts, :window_seconds, @default_window_seconds)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    since = DateTime.add(now, -window_seconds, :second)

    case Zaik.Home.HistoryStore.readings_since(history_store, friendly_name, since, limit: 1_000) do
      {:ok, readings} ->
        readings = Enum.sort_by(readings, & &1.observed_at, DateTime)

        if length(readings) < 2 do
          {:error, :insufficient_data}
        else
          {:ok, build_analysis(friendly_name, readings, window_seconds)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_analysis(friendly_name, readings, window_seconds) do
    %{
      friendly_name: friendly_name,
      window_seconds: window_seconds,
      readings_count: length(readings),
      first_observed_at: readings |> List.first() |> Map.get(:observed_at),
      last_observed_at: readings |> List.last() |> Map.get(:observed_at),
      temperature: numeric_trend(readings, :temperature_f, 0.5),
      humidity: numeric_trend(readings, :humidity, 2.0),
      illuminance: numeric_trend(readings, :illuminance, 50.0),
      presence: last_value(readings, :presence)
    }
  end

  defp numeric_trend(readings, field, threshold) do
    readings
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        nil

      [_single] ->
        nil

      values ->
        first = List.first(values)
        current = List.last(values)
        delta = current - first

        %{
          first: first,
          current: current,
          delta: delta,
          trend: classify_delta(delta, threshold)
        }
    end
  end

  defp classify_delta(delta, threshold) when delta > threshold, do: :rising
  defp classify_delta(delta, threshold) when delta < -threshold, do: :falling
  defp classify_delta(_delta, _threshold), do: :steady

  defp last_value(readings, field) do
    readings
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end
end

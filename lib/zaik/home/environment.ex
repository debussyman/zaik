defmodule Zaik.Home.Environment do
  @moduledoc """
  Deterministic local environmental context for home decisions.

  The initial implementation derives local civil time, configured day/night
  periods, and meteorological season. A future location adapter can replace the
  configured-hour phase with sunrise/sunset while preserving this result shape.
  """

  def config do
    configured = Application.get_env(:zaik, :home_environment, [])

    %{
      utc_offset_minutes:
        env_integer("ZAIK_HOME_UTC_OFFSET_MINUTES") ||
          Keyword.get(configured, :utc_offset_minutes),
      hemisphere:
        System.get_env("ZAIK_HOME_HEMISPHERE") ||
          Keyword.get(configured, :hemisphere, "north"),
      day_start_hour:
        env_integer("ZAIK_HOME_DAY_START_HOUR") ||
          Keyword.get(configured, :day_start_hour, 6),
      night_start_hour:
        env_integer("ZAIK_HOME_NIGHT_START_HOUR") ||
          Keyword.get(configured, :night_start_hour, 20)
    }
  end

  def snapshot(opts \\ []) do
    cfg = Map.merge(config(), Map.new(Keyword.get(opts, :config, %{})))
    now = Zaik.Time.now(Keyword.get(opts, :clock))
    offset = cfg.utc_offset_minutes || system_utc_offset_minutes()
    local = DateTime.add(now, offset * 60, :second)

    %{
      observed_at: DateTime.to_iso8601(now),
      local_date: Date.to_iso8601(DateTime.to_date(local)),
      local_time: Calendar.strftime(local, "%H:%M:%S"),
      local_hour: local.hour,
      utc_offset_minutes: offset,
      season: season(local.month, cfg.hemisphere),
      solar_phase: phase(local.hour, cfg.day_start_hour, cfg.night_start_hour),
      solar_phase_source: "configured_hours"
    }
  end

  defp phase(hour, day_start, night_start)
       when is_integer(day_start) and is_integer(night_start) and day_start < night_start do
    if hour >= day_start and hour < night_start, do: "day", else: "night"
  end

  defp phase(_hour, _day_start, _night_start), do: "unknown"

  defp season(month, hemisphere) do
    northern =
      case month do
        month when month in [12, 1, 2] -> "winter"
        month when month in [3, 4, 5] -> "spring"
        month when month in [6, 7, 8] -> "summer"
        _month -> "autumn"
      end

    if String.downcase(to_string(hemisphere)) in ["south", "southern"] do
      %{"winter" => "summer", "spring" => "autumn", "summer" => "winter", "autumn" => "spring"}[
        northern
      ]
    else
      northern
    end
  end

  defp system_utc_offset_minutes do
    local = :calendar.local_time() |> :calendar.datetime_to_gregorian_seconds()
    utc = :calendar.universal_time() |> :calendar.datetime_to_gregorian_seconds()
    div(local - utc, 60)
  end

  defp env_integer(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> nil
        end
    end
  end
end

defmodule Zaik.Home.Environment do
  @moduledoc """
  Deterministic local environmental context for home decisions.

  It derives local civil time, meteorological season, and—when a calibrated
  latitude/longitude is configured—sunrise/sunset using a deterministic NOAA
  approximation. Configured hours remain the conservative fallback.
  """

  def config do
    configured = Application.get_env(:zaik, :home_environment, [])

    %{
      utc_offset_minutes:
        env_integer("ZAIK_HOME_UTC_OFFSET_MINUTES") ||
          Keyword.get(configured, :utc_offset_minutes),
      timezone: System.get_env("ZAIK_HOME_TIMEZONE") || Keyword.get(configured, :timezone),
      location_name:
        System.get_env("ZAIK_HOME_LOCATION_NAME") || Keyword.get(configured, :location_name),
      latitude: env_float("ZAIK_HOME_LATITUDE") || Keyword.get(configured, :latitude),
      longitude: env_float("ZAIK_HOME_LONGITUDE") || Keyword.get(configured, :longitude),
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

    local_date = DateTime.to_date(local)
    solar = solar_context(local_date, now, offset, cfg)

    %{
      observed_at: DateTime.to_iso8601(now),
      local_date: Date.to_iso8601(local_date),
      local_time: Calendar.strftime(local, "%H:%M:%S"),
      local_hour: local.hour,
      timezone: cfg.timezone,
      utc_offset_minutes: offset,
      location: location(cfg),
      season: season(local.month, cfg.hemisphere),
      solar_phase: solar.phase,
      solar_phase_source: solar.source,
      sunrise_at: solar.sunrise_at,
      sunset_at: solar.sunset_at
    }
  end

  defp phase(hour, day_start, night_start)
       when is_integer(day_start) and is_integer(night_start) and day_start < night_start do
    if hour >= day_start and hour < night_start, do: "day", else: "night"
  end

  defp phase(_hour, _day_start, _night_start), do: "unknown"

  defp solar_context(date, now, offset, %{latitude: latitude, longitude: longitude} = cfg)
       when is_number(latitude) and is_number(longitude) and latitude >= -90 and latitude <= 90 and
              longitude >= -180 and longitude <= 180 do
    with {:ok, sunrise} <- solar_event(date, latitude, longitude, offset, :sunrise),
         {:ok, sunset} <- solar_event(date, latitude, longitude, offset, :sunset) do
      %{
        phase:
          if(DateTime.compare(now, sunrise) in [:eq, :gt] and DateTime.before?(now, sunset),
            do: "day",
            else: "night"
          ),
        source: "sunrise_sunset",
        sunrise_at: DateTime.to_iso8601(sunrise),
        sunset_at: DateTime.to_iso8601(sunset)
      }
    else
      _ -> configured_solar_context(now, offset, cfg)
    end
  end

  defp solar_context(_date, now, offset, cfg), do: configured_solar_context(now, offset, cfg)

  defp configured_solar_context(now, offset, cfg) do
    local = DateTime.add(now, offset * 60, :second)

    %{
      phase: phase(local.hour, cfg.day_start_hour, cfg.night_start_hour),
      source: "configured_hours",
      sunrise_at: nil,
      sunset_at: nil
    }
  end

  defp solar_event(date, latitude, longitude, offset_minutes, event) do
    day = Date.day_of_year(date)
    longitude_hour = longitude / 15.0
    base_hour = if event == :sunrise, do: 6.0, else: 18.0
    approximate = day + (base_hour - longitude_hour) / 24.0
    anomaly = 0.9856 * approximate - 3.289

    true_longitude =
      (anomaly + 1.916 * sin_deg(anomaly) + 0.020 * sin_deg(2 * anomaly) + 282.634)
      |> normalize_degrees()

    right_ascension =
      atan_deg(0.91764 * tan_deg(true_longitude))
      |> normalize_degrees()
      |> then(fn ascension ->
        longitude_quadrant = Float.floor(true_longitude / 90.0) * 90.0
        ascension_quadrant = Float.floor(ascension / 90.0) * 90.0
        (ascension + longitude_quadrant - ascension_quadrant) / 15.0
      end)

    sin_declination = 0.39782 * sin_deg(true_longitude)
    cos_declination = :math.cos(:math.asin(sin_declination))
    zenith = 90.833

    cosine_hour =
      (cos_deg(zenith) - sin_declination * sin_deg(latitude)) /
        (cos_declination * cos_deg(latitude))

    if cosine_hour < -1.0 or cosine_hour > 1.0 do
      {:error, :polar_day_or_night}
    else
      hour_angle =
        case event do
          :sunrise -> 360.0 - acos_deg(cosine_hour)
          :sunset -> acos_deg(cosine_hour)
        end

      local_mean_time = hour_angle / 15.0 + right_ascension - 0.06571 * approximate - 6.622
      utc_hours = normalize_hours(local_mean_time - longitude_hour)
      local_unwrapped = utc_hours + offset_minutes / 60.0

      day_shift =
        cond do
          local_unwrapped < 0 -> 1
          local_unwrapped >= 24 -> -1
          true -> 0
        end

      seconds = round(utc_hours * 3_600)
      midnight = DateTime.new!(Date.add(date, day_shift), ~T[00:00:00], "Etc/UTC")
      {:ok, DateTime.add(midnight, seconds, :second)}
    end
  end

  defp location(cfg) do
    if is_number(cfg.latitude) and is_number(cfg.longitude) do
      %{name: cfg.location_name, latitude: cfg.latitude, longitude: cfg.longitude}
    end
  end

  defp sin_deg(value), do: :math.sin(value * :math.pi() / 180.0)
  defp cos_deg(value), do: :math.cos(value * :math.pi() / 180.0)
  defp tan_deg(value), do: :math.tan(value * :math.pi() / 180.0)
  defp atan_deg(value), do: :math.atan(value) * 180.0 / :math.pi()
  defp acos_deg(value), do: :math.acos(value) * 180.0 / :math.pi()
  defp normalize_degrees(value), do: value - 360.0 * Float.floor(value / 360.0)
  defp normalize_hours(value), do: value - 24.0 * Float.floor(value / 24.0)

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

  defp env_float(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case Float.parse(value) do
          {number, ""} -> number
          _ -> nil
        end
    end
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

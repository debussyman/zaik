defmodule Zaik.Home.EnvironmentTest do
  use ExUnit.Case, async: true

  test "derives deterministic sunrise and sunset from calibrated location" do
    {:ok, clock} =
      start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: ~U[2026-07-15 12:00:00Z]})

    environment =
      Zaik.Home.Environment.snapshot(
        clock: {Zaik.Home.Mirror.Clock, clock},
        config: %{
          timezone: "America/New_York",
          location_name: "New York",
          latitude: 40.7128,
          longitude: -74.006,
          utc_offset_minutes: -240
        }
      )

    assert environment.solar_phase == "day"
    assert environment.solar_phase_source == "sunrise_sunset"
    assert environment.timezone == "America/New_York"
    assert environment.location == %{name: "New York", latitude: 40.7128, longitude: -74.006}

    sunrise = DateTime.from_iso8601(environment.sunrise_at) |> elem(1)
    sunset = DateTime.from_iso8601(environment.sunset_at) |> elem(1)

    assert_in_delta DateTime.diff(sunrise, ~U[2026-07-15 09:38:00Z], :second), 0, 15 * 60
    assert_in_delta DateTime.diff(sunset, ~U[2026-07-16 00:25:00Z], :second), 0, 15 * 60
  end

  test "solar phase transitions against generated event instants" do
    {:ok, clock} =
      start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: ~U[2026-07-15 09:00:00Z]})

    opts = [
      clock: {Zaik.Home.Mirror.Clock, clock},
      config: %{latitude: 40.7128, longitude: -74.006, utc_offset_minutes: -240}
    ]

    assert Zaik.Home.Environment.snapshot(opts).solar_phase == "night"
    Zaik.Home.Mirror.Clock.advance(clock, 60 * 60 * 1_000)
    assert Zaik.Home.Environment.snapshot(opts).solar_phase == "day"
    Zaik.Home.Mirror.Clock.advance(clock, 15 * 60 * 60 * 1_000)
    assert Zaik.Home.Environment.snapshot(opts).solar_phase == "night"
  end

  test "falls back conservatively when location calibration is absent" do
    {:ok, clock} =
      start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: ~U[2026-01-15 12:00:00Z]})

    environment =
      Zaik.Home.Environment.snapshot(
        clock: {Zaik.Home.Mirror.Clock, clock},
        config: %{
          timezone: "America/New_York",
          utc_offset_minutes: -300,
          day_start_hour: 6,
          night_start_hour: 20
        }
      )

    assert environment.solar_phase_source == "configured_hours"
    assert environment.solar_phase == "day"
    assert environment.sunrise_at == nil
    assert environment.sunset_at == nil
    assert environment.location == nil
  end
end

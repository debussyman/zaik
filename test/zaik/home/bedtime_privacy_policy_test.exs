defmodule Zaik.Home.BedtimePrivacyPolicyTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, clock} =
      start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: ~U[2026-07-15 20:00:00Z]})

    %{clock: clock, clock_provider: {Zaik.Home.Mirror.Clock, clock}}
  end

  test "privacy mode closes covers and suppresses daylight by authority", context do
    room = room_context("privacy")

    assert {:ok, [privacy]} =
             Zaik.Home.Policies.BedtimePrivacy.evaluate(room, clock: context.clock_provider)

    assert privacy.priority_class == :privacy_sleep
    assert privacy.priority == 80
    assert Enum.all?(privacy.desired_state, &(&1.target == %{"position" => 100}))

    daylight_room = %{room | home_modes: []}

    assert {:ok, [daylight]} =
             Zaik.Home.Policies.DaylightHarvesting.evaluate(
               daylight_room,
               clock: context.clock_provider,
               maximum_temperature_f: 80.0
             )

    arbitration =
      Zaik.Home.Arbitrator.arbitrate([daylight, privacy], clock: context.clock_provider)

    assert Enum.all?(arbitration.selected, &(&1.policy_id == "bedtime_privacy"))
    assert Enum.all?(arbitration.suppressed, &(&1.reason == "conflicting_lower_priority"))
  end

  test "bedtime mode requires per-device bedtime presets", context do
    room = room_context("bedtime")

    assert {:ok, []} =
             Zaik.Home.Policies.BedtimePrivacy.evaluate(room, clock: context.clock_provider)

    room =
      Map.put(room, :device_presets, [
        preset("Left blind", 100),
        preset("Right blind", 71)
      ])

    assert {:ok, [candidate]} =
             Zaik.Home.Policies.BedtimePrivacy.evaluate(room, clock: context.clock_provider)

    assert Enum.map(candidate.desired_state, & &1.target) == [
             %{"position" => 100},
             %{"position" => 71}
           ]

    assert candidate.evidence.target_strategy.preset == "bedtime"
  end

  test "manual cover override suppresses active modes", context do
    room =
      room_context("privacy")
      |> Map.put(:manual_overrides, [%{capability: "cover"}])

    assert {:ok, []} =
             Zaik.Home.Policies.BedtimePrivacy.evaluate(room, clock: context.clock_provider)
  end

  defp room_context(mode) do
    %{
      snapshot_id: "snapshot",
      areas: ["lily_bedroom"],
      occupancy: %{status: "occupied", confidence: 1.0},
      environment: %{solar_phase: "day"},
      history: %{
        "temperature_f" => %{sample_count: 4, freshness_seconds: 30, average: 72.0}
      },
      home_modes: [
        %{
          id: "mode-1",
          scope: "lily_bedroom",
          mode: mode,
          owner: "parent",
          reason: "test",
          created_at: "2026-07-15T20:00:00Z",
          expires_at: "2026-07-15T21:00:00Z"
        }
      ],
      manual_overrides: [],
      device_presets: [],
      entities: [
        %{
          id: "left",
          name: "Left blind",
          capabilities: ["cover"],
          state: %{"cover" => %{position: 100}}
        },
        %{
          id: "right",
          name: "Right blind",
          capabilities: ["cover"],
          state: %{"cover" => %{position: 100}}
        },
        %{
          id: "sensor",
          name: "Sensor",
          capabilities: ["temperature", "illuminance", "presence"],
          state: %{
            "temperature" => %{fahrenheit: 72.0},
            "illuminance" => %{value: 10},
            "presence" => %{detected: true}
          }
        }
      ]
    }
  end

  defp preset(device, position) do
    %{
      "device_name" => device,
      "preset_name" => "bedtime",
      "capability" => "cover",
      "target" => %{"position" => position}
    }
  end
end

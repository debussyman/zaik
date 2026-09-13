defmodule Zaik.Home.SolarHeatAvoidancePolicyTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, clock} =
      start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: ~U[2026-07-15 14:00:00Z]})

    %{clock: clock, provider: {Zaik.Home.Mirror.Clock, clock}}
  end

  test "hot bright rooms use calibrated presets and outrank daylight", context do
    room = room_context(80.0, 1_500)

    assert {:ok, [solar]} =
             Zaik.Home.Policies.SolarHeatAvoidance.evaluate(room, clock: context.provider)

    assert solar.priority_class == :comfort
    assert solar.priority == 60

    assert Enum.map(solar.desired_state, & &1.target) == [
             %{"position" => 100},
             %{"position" => 71}
           ]

    assert {:ok, [daylight]} =
             Zaik.Home.Policies.DaylightHarvesting.evaluate(
               room,
               clock: context.provider,
               maximum_temperature_f: 82.0,
               low_light_lux: 2_000
             )

    arbitration = Zaik.Home.Arbitrator.arbitrate([daylight, solar], clock: context.provider)
    assert Enum.all?(arbitration.selected, &(&1.policy_id == "solar_heat_avoidance"))
    assert Enum.all?(arbitration.suppressed, &(&1.reason == "conflicting_lower_priority"))
  end

  test "missing calibration or manual overrides block conservatively", context do
    room = room_context(80.0, 1_500)

    assert {:ok, []} =
             Zaik.Home.Policies.SolarHeatAvoidance.evaluate(
               %{room | device_presets: []},
               clock: context.provider
             )

    assert {:ok, []} =
             Zaik.Home.Policies.SolarHeatAvoidance.evaluate(
               %{room | manual_overrides: [%{capability: "cover"}]},
               clock: context.provider
             )
  end

  test "active target uses release hysteresis and minimum hold", context do
    now = Zaik.Home.Mirror.Clock.now(context.clock)

    lease = %{
      source_id: "solar_heat_avoidance",
      capability: "cover",
      status: "active",
      created_at: DateTime.to_iso8601(now)
    }

    room = room_context(75.0, 800) |> Map.put(:desired_state_leases, [lease])

    assert {:ok, [holding]} =
             Zaik.Home.Policies.SolarHeatAvoidance.evaluate(room, clock: context.provider)

    assert holding.evidence.phase == "holding"
    assert holding.evidence.minimum_hold == true

    Zaik.Home.Mirror.Clock.advance(context.clock, 301_000)

    assert {:ok, []} =
             Zaik.Home.Policies.SolarHeatAvoidance.evaluate(room, clock: context.provider)
  end

  defp room_context(temperature_f, illuminance) do
    %{
      snapshot_id: "snapshot",
      areas: ["lily_bedroom"],
      environment: %{solar_phase: "day"},
      occupancy: %{status: "occupied", confidence: 1.0},
      history: %{
        "temperature_f" => %{sample_count: 4, freshness_seconds: 30, average: temperature_f}
      },
      manual_overrides: [],
      desired_state_leases: [],
      device_presets: [preset("Left blind", 100), preset("Right blind", 71)],
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
          capabilities: ["temperature", "illuminance"],
          state: %{
            "temperature" => %{fahrenheit: temperature_f},
            "illuminance" => %{value: illuminance}
          }
        }
      ]
    }
  end

  defp preset(device, position) do
    %{
      "device_name" => device,
      "preset_name" => "solar heat",
      "capability" => "cover",
      "target" => %{"position" => position}
    }
  end
end

defmodule Zaik.Home.PolicyTest do
  use ExUnit.Case, async: true

  defmodule InvalidPolicy do
    def descriptor, do: %{id: "broken"}
    def evaluate(_context, _opts), do: {:ok, []}
  end

  setup do
    {:ok, clock} =
      start_supervised(
        {Zaik.Home.Mirror.Clock, name: nil, now: ~U[2026-07-15 14:00:00Z]},
        id: :policy_clock
      )

    %{clock: clock}
  end

  test "daylight harvesting emits an inert typed candidate", %{clock: clock} do
    context = room_context()

    assert {:ok, [candidate]} =
             Zaik.Home.Policies.DaylightHarvesting.evaluate(context,
               clock: {Zaik.Home.Mirror.Clock, clock}
             )

    assert %Zaik.Home.GoalCandidate{} = candidate
    assert candidate.policy_id == "daylight_harvesting"
    assert candidate.scope == "lily_bedroom"
    assert candidate.priority == 40
    assert candidate.evidence.snapshot_id == "snapshot-1"
    assert candidate.evidence.illuminance_lux == 18
    assert candidate.evidence.temperature_f == 72.0

    assert candidate.desired_state == [
             %{
               entity_id: "left",
               device: "Lily's bedroom left blind",
               capability: "cover",
               target: %{"position" => 0}
             },
             %{
               entity_id: "right",
               device: "Lily's bedroom right blind",
               capability: "cover",
               target: %{"position" => 0}
             }
           ]
  end

  test "daylight harvesting is suppressed by night, heat, vacancy, or override", %{clock: clock} do
    base = room_context()
    opts = [clock: {Zaik.Home.Mirror.Clock, clock}]

    assert {:ok, []} =
             Zaik.Home.Policies.DaylightHarvesting.evaluate(
               put_in(base, [:environment, :solar_phase], "night"),
               opts
             )

    assert {:ok, []} =
             Zaik.Home.Policies.DaylightHarvesting.evaluate(
               put_in(base, [:history, "temperature_f", :average], 80.0),
               opts
             )

    assert {:ok, []} =
             Zaik.Home.Policies.DaylightHarvesting.evaluate(
               put_in(base, [:occupancy, :status], "vacant"),
               opts
             )

    assert {:ok, []} =
             Zaik.Home.Policies.DaylightHarvesting.evaluate(
               Map.put(base, :manual_override, %{active: true}),
               opts
             )
  end

  test "generated daylight state matrix emits only for the complete eligible context", %{
    clock: clock
  } do
    for occupied? <- [false, true],
        daytime? <- [false, true],
        dark? <- [false, true],
        cool? <- [false, true],
        closed? <- [false, true] do
      context =
        room_context()
        |> put_in([:occupancy, :status], if(occupied?, do: "occupied", else: "vacant"))
        |> put_in([:environment, :solar_phase], if(daytime?, do: "day", else: "night"))
        |> put_in(
          [:entities, Access.at(0), :state, "illuminance", :value],
          if(dark?, do: 18, else: 200)
        )
        |> put_in([:history, "temperature_f", :average], if(cool?, do: 72.0, else: 82.0))
        |> put_in(
          [:entities, Access.at(1), :state, "cover", :position],
          if(closed?, do: 100, else: 0)
        )
        |> put_in(
          [:entities, Access.at(2), :state, "cover", :position],
          if(closed?, do: 100, else: 0)
        )

      assert {:ok, candidates} =
               Zaik.Home.Policies.DaylightHarvesting.evaluate(context,
                 clock: {Zaik.Home.Mirror.Clock, clock}
               )

      expected? = occupied? and daytime? and dark? and cool? and closed?
      assert candidates != [] == expected?
    end
  end

  test "policy registry evaluates only changed dependencies", %{clock: clock} do
    assert {:ok, []} =
             Zaik.Home.Policies.Registry.evaluate_all(room_context(),
               changed_dependencies: ["battery"],
               policy_opts: [clock: {Zaik.Home.Mirror.Clock, clock}]
             )

    assert {:ok, [_candidate]} =
             Zaik.Home.Policies.Registry.evaluate_all(room_context(),
               changed_dependencies: ["presence"],
               policy_opts: [clock: {Zaik.Home.Mirror.Clock, clock}]
             )
  end

  test "policy registry is runtime validated and fingerprinted" do
    assert :ok = Zaik.Home.Policies.Registry.validate()

    assert {:ok, %{descriptor: descriptor}} =
             Zaik.Home.Policies.Registry.fetch("DAYLIGHT_HARVESTING")

    assert descriptor.default_mode == :shadow

    assert descriptor.dependencies == [
             "presence",
             "illuminance",
             "temperature",
             "cover",
             "environment"
           ]

    assert byte_size(Zaik.Home.Policies.Registry.fingerprint()) == 64

    assert {:error, {:policy_contract_errors, _errors}} =
             Zaik.Home.Policies.Registry.validate(modules: [InvalidPolicy])
  end

  test "candidate validation rejects unknown capabilities", %{clock: clock} do
    now = Zaik.Home.Mirror.Clock.now(clock)

    assert {:error, {:invalid_desired_state, 0, {:unknown_capability, "teleport"}}} =
             Zaik.Home.GoalCandidate.new(%{
               policy_id: "bad",
               policy_version: "1",
               scope: "room",
               priority: 1,
               desired_state: [
                 %{
                   entity_id: "device",
                   device: "Device",
                   capability: "teleport",
                   target: %{"state" => "ON"}
                 }
               ],
               evidence: %{},
               reason: "invalid",
               created_at: now,
               expires_at: DateTime.add(now, 60, :second)
             })
  end

  defp room_context do
    %{
      snapshot_id: "snapshot-1",
      query: "Lily's room",
      areas: ["lily_bedroom"],
      occupancy: %{status: "occupied"},
      environment: %{solar_phase: "day", season: "summer"},
      history: %{"temperature_f" => %{status: "ok", average: 72.0}},
      entities: [
        %{
          id: "sensor",
          name: "Lily's room sensor",
          state: %{
            "temperature" => %{fahrenheit: 72.0},
            "illuminance" => %{value: 18},
            "presence" => %{detected: true}
          }
        },
        %{
          id: "left",
          name: "Lily's bedroom left blind",
          state: %{"cover" => %{position: 100}}
        },
        %{
          id: "right",
          name: "Lily's bedroom right blind",
          state: %{"cover" => %{position: 100}}
        }
      ]
    }
  end
end

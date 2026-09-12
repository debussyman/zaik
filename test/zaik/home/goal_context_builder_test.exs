defmodule Zaik.Home.GoalContextBuilderTest do
  use ExUnit.Case, async: true

  setup do
    now = ~U[2026-07-15 14:00:00Z]
    {:ok, clock} = start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: now})
    {:ok, devices} = start_supervised({Zaik.Home.DeviceStore, name: nil, event_bus: false})
    {:ok, history} = start_supervised({Zaik.Home.HistoryStore, name: nil, db_path: ":memory:"})

    {:ok, presets} =
      start_supervised(
        {Zaik.Home.DevicePresetStore,
         name: nil, db_path: ":memory:", import_legacy_blind_presets?: false}
      )

    sensor = %{
      "ieee_address" => "sensor",
      "area_id" => "lily_bedroom",
      "observed_at" => now,
      "source" => "test"
    }

    Zaik.Home.DeviceStore.upsert_device(
      devices,
      "Lily's room sensor",
      %{"temperature" => 22.0, "presence" => true},
      sensor
    )

    :ok =
      Zaik.Home.HistoryStore.record_device(
        history,
        "Lily's room sensor",
        %{"temperature" => 22.0},
        sensor,
        observed_at: DateTime.add(now, -300, :second)
      )

    for {name, id} <- [
          {"Lily's bedroom left blind", "left"},
          {"Lily's bedroom right blind", "right"}
        ] do
      Zaik.Home.DeviceStore.upsert_device(devices, name, %{"position" => 100}, %{
        "ieee_address" => id,
        "area_id" => "lily_bedroom",
        "observed_at" => now,
        "source" => "test"
      })
    end

    {:ok, _} =
      Zaik.Home.DevicePresetStore.put(
        "Lily's bedroom right blind",
        "above AC",
        "cover",
        %{"position" => 71},
        %{source: "test"},
        presets
      )

    skill_path =
      Path.join(System.tmp_dir!(), "zaik-goal-skills-#{System.unique_integer([:positive])}")

    File.mkdir_p!(skill_path)
    File.write!(Path.join(skill_path, "lily_bedtime.md"), skill_text())
    on_exit(fn -> File.rm_rf(skill_path) end)

    %{clock: clock, devices: devices, history: history, presets: presets, skill_path: skill_path}
  end

  test "builds independently gathered evidence for a versioned goal", context do
    assert {:ok, result} = Zaik.Home.GoalContextBuilder.build(skill(), bindings(context))
    assert result.status == "ready"
    assert result.goal_id == "lily_bedtime"
    assert result.scope == "lily_bedroom"
    assert result.room.snapshot_id

    assert Enum.map(result.evidence, & &1.requirement) == [
             "environment.solar_phase",
             "environment.season",
             "history.temperature_f",
             "capability.cover",
             "presets.cover"
           ]

    assert Enum.all?(result.evidence, &(&1.status == "ok"))
    assert [%{"preset_name" => "above AC", "target" => %{"position" => 71}}] = result.presets

    Zaik.Home.Mirror.Clock.advance(context.clock, 1_000)

    assert {:ok, one_second_later} =
             Zaik.Home.GoalContextBuilder.build(skill(), bindings(context))

    assert one_second_later.fingerprint == result.fingerprint
  end

  test "registered read tool resolves a semantic goal ID without phrase routing", context do
    tool_context =
      context
      |> bindings()
      |> Map.new()
      |> Map.put(:skill_opts, paths: [context.skill_path])

    assert {:ok, result} =
             Zaik.Tools.Registry.run(
               "get_home_goal_context",
               %{"goal_id" => "lily_bedtime"},
               tool_context
             )

    assert result.status == "ready"
    assert result.goal_id == "lily_bedtime"
  end

  test "versioned skill plans require a current evidence fingerprint", context do
    [active_skill] = Zaik.SkillStore.list(paths: [context.skill_path])

    tool_context =
      context
      |> bindings()
      |> Map.new()
      |> Map.put(:skill_opts, paths: [context.skill_path])
      |> Map.put(:active_skills, [active_skill])

    args = %{
      "goal" => "bedtime",
      "goal_id" => "lily_bedtime",
      "actions" => [
        %{
          "device" => "Lily's bedroom left blind",
          "capability" => "cover",
          "target" => %{"position" => 100}
        }
      ]
    }

    assert {:error, :goal_evidence_required} =
             Zaik.Home.Tools.ExecutePlan.run(Map.delete(args, "goal_id"), tool_context)

    assert {:error, :goal_context_fingerprint_required} =
             Zaik.Home.Tools.ExecutePlan.run(args, tool_context)

    assert {:error, :goal_context_changed} =
             Zaik.Home.Tools.ExecutePlan.run(
               Map.put(args, "goal_context_fingerprint", String.duplicate("0", 64)),
               tool_context
             )

    assert {:ok, gathered} =
             Zaik.Home.GoalContextBuilder.build(
               "lily_bedtime",
               bindings(context) ++ [skill_opts: [paths: [context.skill_path]]]
             )

    invalid_after_evidence =
      args
      |> Map.put("goal_context_fingerprint", gathered.fingerprint)
      |> put_in(["actions", Access.at(0), "device"], "Unknown blind")

    assert {:error, {:invalid_action_plan, [%{reason: :not_found}]}} =
             Zaik.Home.Tools.ExecutePlan.run(invalid_after_evidence, tool_context)
  end

  test "blocks when required canonical cover evidence is stale", context do
    Zaik.Home.Mirror.Clock.advance(context.clock, 121_000)

    assert {:error, {:missing_required_observations, ["capability.cover"], result}} =
             Zaik.Home.GoalContextBuilder.build(skill(), bindings(context))

    assert result.status == "missing_data"
    assert result.fingerprint
  end

  test "rejects incomplete or unsupported skill contracts" do
    assert {:error, {:invalid_goal_contract, errors}} =
             Zaik.Home.GoalContract.new(%{contract: %{schema_version: 2, goal_id: "", scope: ""}})

    assert {:unsupported_schema_version, 2} in errors
    assert :missing_goal_id in errors
    assert :missing_scope in errors
  end

  defp bindings(context) do
    [
      clock: {Zaik.Home.Mirror.Clock, context.clock},
      device_store: context.devices,
      history_store: context.history,
      occupancy_tracker: false,
      manual_override_store: false,
      preset_store: context.presets,
      environment_config: %{utc_offset_minutes: 0},
      max_state_age_seconds: 120
    ]
  end

  defp skill_text do
    """
    ---
    name: lily_bedtime
    domain: home
    risk: low
    schema_version: 1
    goal_id: lily_bedtime
    scope: lily_bedroom
    risk_ceiling: low
    missing_data_policy: block
    required_observations:
      - environment.solar_phase
      - environment.season
      - history.temperature_f
      - capability.cover
      - presets.cover
    preferences:
      - preserve cooling airflow
    constraints:
      - right blind uses above AC
    allowed_tools:
      - get_home_goal_context
      - execute_home_plan
    ---

    Prepare the room for bedtime while preserving cooling airflow.
    """
  end

  defp skill do
    %{
      name: "Lily bedtime",
      risk: "low",
      allowed_tools: ["execute_home_plan"],
      contract: %{
        schema_version: 1,
        goal_id: "lily_bedtime",
        scope: "lily_bedroom",
        required_observations: [
          "environment.solar_phase",
          "environment.season",
          "history.temperature_f",
          "capability.cover",
          "presets.cover"
        ],
        preferences: ["preserve cooling airflow"],
        constraints: ["right blind may use above AC"],
        allowed_tools: ["execute_home_plan"],
        risk_ceiling: "low",
        missing_data_policy: "block"
      }
    }
  end
end

defmodule Zaik.AgentChat.RoutingEvals do
  @moduledoc """
  Deterministic evals for skill-aware routing, prompt construction, and SQL guards.

  These do not call an LLM. They are intended to catch regressions where a skill
  hijacks an unrelated read question, a home-control request gets the wrong
  prompt, or a known-bad SQL plan would let null blind rows mask sensor data.
  """

  def cases do
    [
      %{
        name: "temperature_question_not_hijacked_by_lily_skill",
        kind: :domain,
        prompt: "What's the temperature in Lily's room",
        expected_domain: :home_readings,
        prompt_must_include: [
          "DOMAIN: home sensor readings and trends",
          "MODE: current typed state",
          "Required and only available tool: get_home_state"
        ],
        prompt_must_not_include: ["DOMAIN: home control"]
      },
      %{
        name: "room_status_question_not_hijacked_by_lily_skill",
        kind: :domain,
        prompt: "How's Lily's room?",
        expected_domain: :home_readings,
        prompt_must_include: ["DOMAIN: home sensor readings and trends"],
        prompt_must_not_include: ["DOMAIN: home control"]
      },
      %{
        name: "temperature_trend_question_not_home_control",
        kind: :domain,
        prompt: "Is Lily's room getting warmer or cooler?",
        expected_domain: :home_readings,
        prompt_must_include: ["get_home_history"],
        prompt_must_not_include: ["control_blind"]
      },
      %{
        name: "bedtime_ac_setup_routes_home_control",
        kind: :domain,
        prompt: "Set up Lily's room for bedtime with AC",
        expected_domain: :home_control,
        prompt_must_include: [
          "DOMAIN: home control",
          "execute_home_plan",
          "lily_bedtime_with_ac",
          "above AC"
        ],
        prompt_must_not_include: []
      },
      %{
        name: "open_blinds_routes_home_control",
        kind: :domain,
        prompt: "Open Lily's left blind",
        expected_domain: :home_control,
        prompt_must_include: ["DOMAIN: home control", "control_device"],
        prompt_must_not_include: []
      },
      %{
        name: "home_action_status_routes_to_read_tool",
        kind: :domain,
        prompt: "Check home action status abc123",
        expected_domain: :home_action_status,
        prompt_must_include: [
          "DOMAIN: home action status",
          "Required first tool: get_home_action_status"
        ],
        prompt_must_not_include: ["retry_home_action", "control_device"]
      },
      %{
        name: "explicit_action_retry_routes_to_policy_tool",
        kind: :domain,
        prompt: "Retry home action abc123",
        expected_domain: :home_control,
        prompt_must_include: [
          "DOMAIN: home control",
          "Required action tool: retry_home_action",
          "Only retry_home_action may approve"
        ],
        prompt_must_not_include: ["DOMAIN: operational tasks"]
      },
      %{
        name: "latest_temperature_requires_non_null_filter",
        kind: :sql_guard,
        sql:
          "SELECT recorded_at, temperature_f FROM home_readings WHERE lower(device_name) LIKE '%lily%' ORDER BY recorded_at DESC LIMIT 1",
        expected_error: {:missing_non_null_filter, "temperature_f"}
      },
      %{
        name: "latest_temperature_rejects_mis_scoped_or_filter",
        kind: :sql_guard,
        sql:
          "SELECT recorded_at, temperature_f FROM home_readings WHERE lower(device_name) LIKE '%lily%' OR lower(room) LIKE '%lily%' AND temperature_f IS NOT NULL ORDER BY recorded_at DESC LIMIT 1",
        expected_error: {:mis_scoped_non_null_filter, "temperature_f"}
      },
      %{
        name: "home_sql_rejects_room_name_column",
        kind: :sql_guard,
        sql:
          "SELECT temperature_f FROM home_readings WHERE lower(room_name) LIKE '%lily%' LIMIT 1",
        expected_error: {:unknown_home_column, "room_name"}
      },
      %{
        name: "home_sql_rejects_friendly_name_on_home_readings",
        kind: :sql_guard,
        sql:
          "SELECT temperature_f FROM home_readings WHERE lower(friendly_name) LIKE '%lily%' LIMIT 1",
        expected_error: {:unknown_home_column, "friendly_name"}
      },
      %{
        name: "home_sql_rejects_device_column",
        kind: :sql_guard,
        sql: "SELECT temperature_f FROM home_readings WHERE lower(device) LIKE '%lily%' LIMIT 1",
        expected_error: {:unknown_home_column, "device"}
      },
      %{
        name: "home_sql_accepts_persisted_area_id_column",
        kind: :sql_guard,
        sql: "SELECT temperature_f FROM home_readings WHERE area_id = 'lily_bedroom' LIMIT 10",
        expected_ok?: true
      },
      %{
        name: "latest_temperature_accepts_parenthesized_non_null_filter",
        kind: :sql_guard,
        sql:
          "SELECT recorded_at, temperature_f FROM home_readings WHERE (lower(device_name) LIKE '%lily%' OR lower(room) LIKE '%lily%') AND temperature_f IS NOT NULL ORDER BY recorded_at DESC LIMIT 1",
        expected_ok?: true
      }
    ]
  end

  def run(opts \\ []) do
    with_fixture_context(fn ->
      results = Enum.map(cases(), &run_case(&1, opts))

      %{
        passed: Enum.count(results, & &1.passed?),
        failed: Enum.count(results, &(not &1.passed?)),
        results: results
      }
    end)
  end

  defp run_case(%{kind: :domain} = case_def, _opts) do
    domain = Zaik.AgentChat.Prompts.domain(case_def.prompt)
    prompt = Zaik.AgentChat.Prompts.planner(case_def.prompt, %{})

    checks = [
      check(:domain_matches, domain == case_def.expected_domain),
      check(
        :prompt_includes_required_terms,
        terms_present?(prompt, case_def.prompt_must_include)
      ),
      check(
        :prompt_excludes_forbidden_terms,
        not terms_present?(prompt, case_def.prompt_must_not_include)
      )
    ]

    result(case_def, %{domain: domain, planner_prompt: prompt}, checks)
  end

  defp run_case(%{kind: :sql_guard} = case_def, _opts) do
    validation = Zaik.Analytics.SQLTool.validate(case_def.sql, :home)

    checks =
      cond do
        Map.get(case_def, :expected_ok?) == true ->
          [check(:sql_validation_ok, match?({:ok, _}, validation))]

        Map.has_key?(case_def, :expected_error) ->
          [check(:sql_validation_error_matches, validation == {:error, case_def.expected_error})]
      end

    result(case_def, %{validation: validation}, checks)
  end

  defp result(case_def, data, checks) do
    %{
      name: case_def.name,
      prompt: Map.get(case_def, :prompt),
      data: data,
      checks: checks,
      passed?: Enum.all?(checks, & &1.passed?)
    }
  end

  defp with_fixture_context(fun) do
    original_skills = Application.get_env(:zaik, :skills)
    original_blinds = Application.get_env(:zaik, :blinds)

    skills_path =
      Path.join(
        System.tmp_dir!(),
        "zaik-routing-eval-skills-#{System.unique_integer([:positive])}"
      )

    device_store = nil
    preset_store = nil

    try do
      File.mkdir_p!(skills_path)
      File.write!(Path.join(skills_path, "lily_bedtime_with_ac.md"), lily_skill())

      {:ok, device_store} = GenServer.start_link(Zaik.Home.DeviceStore, [])

      {:ok, preset_store} =
        GenServer.start_link(Zaik.Home.DevicePresetStore, name: nil, db_path: ":memory:")

      Zaik.Home.DeviceStore.upsert_device(device_store, "Lily's room multi-sensor", %{
        "temperature" => 26.7,
        "humidity" => 52,
        "illuminance" => 1,
        "presence" => false
      })

      Zaik.Home.DeviceStore.upsert_device(device_store, "Lily's bedroom left blind", %{
        "position" => 100,
        "state" => "OPEN",
        "linkquality" => 116
      })

      Zaik.Home.DeviceStore.upsert_device(device_store, "Lily's bedroom right blind", %{
        "position" => 71,
        "state" => "OPEN",
        "linkquality" => 124
      })

      Zaik.Home.DevicePresetStore.put(
        "Lily's bedroom right blind",
        "above AC",
        "cover",
        %{"position" => 71},
        %{source: "eval"},
        preset_store
      )

      Application.put_env(:zaik, :skills, enabled: true, paths: [skills_path], max_relevant: 3)

      Application.put_env(:zaik, :blinds,
        base_topic: "zigbee2mqtt",
        device_store: device_store,
        preset_store: preset_store,
        mqtt_client: Zaik.MQTT.Client
      )

      fun.()
    after
      Application.put_env(:zaik, :skills, original_skills || [])
      Application.put_env(:zaik, :blinds, original_blinds || [])
      stop_if_pid(device_store)
      stop_if_pid(preset_store)
      File.rm_rf(skills_path)
    end
  end

  defp stop_if_pid(pid) when is_pid(pid), do: GenServer.stop(pid, :normal, 1_000)
  defp stop_if_pid(_pid), do: :ok

  defp lily_skill do
    """
    ---
    name: lily_bedtime_with_ac
    domain: home
    risk: low
    allowed_tools:
      - get_home_state
      - execute_home_plan
      - control_device
    triggers:
      - Lily bedtime with AC
      - set up Lily's room for bedtime with AC
    ---

    When the user asks to set up Lily's room for bedtime with AC:
    1. Close Lily's bedroom left blind fully.
    2. Set Lily's bedroom right blind to the preset named "above AC".
    """
  end

  defp check(name, passed?), do: %{name: name, passed?: passed?}

  defp terms_present?(_text, []), do: false

  defp terms_present?(text, terms) do
    Enum.all?(terms, &String.contains?(text, &1))
  end
end

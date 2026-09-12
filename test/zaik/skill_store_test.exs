defmodule Zaik.SkillStoreTest do
  use ExUnit.Case, async: false

  setup do
    path = Path.join(System.tmp_dir!(), "zaik-skills-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    File.write!(Path.join(path, "lily_bedtime_with_ac.md"), """
    ---
    name: lily_bedtime_with_ac
    domain: home
    risk: low
    schema_version: 1
    goal_id: lily_bedtime
    scope: lily_bedroom
    risk_ceiling: low
    missing_data_policy: block
    required_observations:
      - environment.solar_phase
      - history.temperature_f
      - capability.cover
      - presets.cover
    preferences:
      - preserve cooling airflow
    constraints:
      - right blind may use above AC
    allowed_tools:
      - control_blind
    triggers:
      - Lily bedtime with AC
    ---

    Close Lily's left blind and set the right blind to above AC.
    """)

    %{path: path}
  end

  test "loads and ranks relevant markdown skills", %{path: path} do
    assert [skill] = Zaik.SkillStore.relevant("please set up Lily bedtime with AC", paths: [path])
    assert skill.name == "lily_bedtime_with_ac"
    assert skill.domain == "home"
    assert "control_blind" in skill.allowed_tools
    assert skill.contract.schema_version == 1
    assert skill.contract.goal_id == "lily_bedtime"
    assert skill.contract.scope == "lily_bedroom"
    assert "presets.cover" in skill.contract.required_observations
    assert skill.contract.preferences == ["preserve cooling airflow"]
    assert Zaik.SkillStore.format_for_prompt([skill]) =~ "Close Lily's left blind"
  end
end

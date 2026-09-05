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
    assert Zaik.SkillStore.format_for_prompt([skill]) =~ "Close Lily's left blind"
  end
end

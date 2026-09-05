defmodule Zaik.AgentChat.PromptsTest do
  use ExUnit.Case, async: false

  test "house prompt includes current time context without hardcoding this morning semantics" do
    prompt = Zaik.AgentChat.Prompts.planner("what changed in Lily's room this morning?", %{})

    assert prompt =~ "CURRENT TIME CONTEXT"
    assert prompt =~ "utc_now:"
    assert prompt =~ "local_now:"
    assert prompt =~ "local_utc_offset:"
    assert prompt =~ "Interpret natural-language time phrases"
    refute prompt =~ "this_morning_start"
    refute prompt =~ "Do NOT interpret \"this morning\""
  end

  test "bedroom questions route to dynamic home readings prompt" do
    assert Zaik.AgentChat.Prompts.domain("what's it like in the main bedroom?") == :home_readings

    prompt = Zaik.AgentChat.Prompts.planner("what's it like in the main bedroom?", %{})

    assert prompt =~ "DOMAIN: home sensor readings and trends"
    assert prompt =~ "MODE: current typed state"
    assert prompt =~ "main bedroom"
    assert prompt =~ "get_home_state"
    refute prompt =~ "DOMAIN: general conversation"
  end

  test "temperature questions route to home readings even when a Lily home skill exists" do
    original = Application.get_env(:zaik, :skills)

    path =
      Path.join(System.tmp_dir!(), "zaik-prompt-skills-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)

    File.write!(Path.join(path, "lily_bedtime_with_ac.md"), """
    ---
    name: lily_bedtime_with_ac
    domain: home
    triggers:
      - Lily bedtime with AC
    ---

    Set up Lily's room for bedtime with AC by closing blinds.
    """)

    Application.put_env(:zaik, :skills, enabled: true, paths: [path], max_relevant: 3)

    on_exit(fn ->
      Application.put_env(:zaik, :skills, original || [])
      File.rm_rf(path)
    end)

    assert Zaik.AgentChat.Prompts.domain("What's the temperature in Lily's room") ==
             :home_readings

    prompt = Zaik.AgentChat.Prompts.planner("What's the temperature in Lily's room", %{})

    assert prompt =~ "DOMAIN: home sensor readings and trends"
    assert prompt =~ "Required and only available tool: get_home_state"
    assert prompt =~ ~s("query":"lily")
    refute prompt =~ "DOMAIN: home control"
  end

  test "home setup/control requests route to home-control prompt" do
    assert Zaik.AgentChat.Prompts.domain("Set up Lily's room for bedtime with AC") ==
             :home_control

    prompt = Zaik.AgentChat.Prompts.planner("Set up Lily's room for bedtime with AC", %{})

    assert prompt =~ "DOMAIN: home control"
    assert prompt =~ "execute_home_plan"
    assert prompt =~ "control_device"
    assert prompt =~ "RELEVANT SKILLS"
    assert prompt =~ "CURRENT BLINDS"
    assert prompt =~ "DEVICE PRESETS"
  end

  test "known dynamic device names classify as home readings without static room keywords" do
    assert Zaik.AgentChat.Prompts.domain("what's it like in the conservatory?",
             home_device_names: ["Conservatory FP300"]
           ) == :home_readings

    assert Zaik.AgentChat.Prompts.domain("how is the garage?",
             home_device_names: ["Garage climate sensor"]
           ) == :home_readings

    assert Zaik.AgentChat.Prompts.domain("what's it like in the conservatory?",
             home_device_names: ["Garage climate sensor"]
           ) == :general
  end
end

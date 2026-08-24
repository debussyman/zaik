defmodule Zaik.AgentChat.PromptsTest do
  use ExUnit.Case, async: true

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
    assert prompt =~ "Device and room names are dynamic"
    assert prompt =~ "main bedroom"
    assert prompt =~ "home_devices"
    refute prompt =~ "DOMAIN: general conversation"
  end
end

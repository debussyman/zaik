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
end

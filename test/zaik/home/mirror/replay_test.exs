defmodule Zaik.Home.Mirror.ReplayTest do
  use ExUnit.Case, async: true

  test "sanitizes a failed production trace into a fingerprinted replay scenario" do
    template = Zaik.Home.Mirror.Scenarios.lily_bedtime_with_ac(id: "sanitized-replay")

    trace = %{
      prompt: "close Lily's blinds",
      sender_id: "12345",
      chat_id: "-999",
      result: {:error, :invalid_cover_target},
      tool_calls: [
        %{
          tool: "control_device",
          args: %{"device" => "Lily's bedroom left blind"},
          error: "invalid_cover_target"
        }
      ]
    }

    assert {:ok, scenario} =
             Zaik.Home.Mirror.Replay.from_trace(template, trace,
               replacements: %{"Lily's" => "Child's"}
             )

    refute Map.has_key?(scenario.metadata.replay_trace, :prompt)
    refute Map.has_key?(scenario.metadata.replay_trace, :sender_id)
    assert scenario.metadata.replay_failure_labels == ["validation"]
    assert scenario.metadata.replay_source_fingerprint =~ ~r/^[0-9a-f]{64}$/
    assert inspect(scenario.metadata.replay_trace) =~ "Child's bedroom left blind"
  end

  test "capability changes produce a scenario carrying old and current fingerprints" do
    template = Zaik.Home.Mirror.Scenarios.lily_bedtime_with_ac(id: "capability-change")

    assert {:ok, scenario} = Zaik.Home.Mirror.Replay.capability_change(template, "old-contract")
    assert scenario.metadata.capability_change_from == "old-contract"

    assert scenario.metadata.capability_fingerprint ==
             Zaik.Home.Capabilities.Registry.fingerprint()
  end
end

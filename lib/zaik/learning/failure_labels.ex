defmodule Zaik.Learning.FailureLabels do
  @moduledoc """
  Stable, coarse labels for evaluation and training trajectories.

  Labels classify observable boundary failures; they do not expose model
  reasoning and never turn policy rejection into a circumvention example.
  """

  @labels ~w(planning validation policy transport non-convergence user-feedback)

  def labels, do: @labels

  def classify(result, tool_calls \\ []) do
    text = inspect({result, tool_calls}, limit: :infinity) |> String.downcase()

    labels = Enum.filter(@labels, &matches?(&1, result, tool_calls, text))

    if labels == [] and error_result?(result), do: ["planning"], else: labels
  end

  defp error_result?({:error, _reason}), do: true
  defp error_result?(_result), do: false

  defp matches?("planning", result, _calls, text) do
    match?({:error, _}, result) and
      contains_any?(text, [
        "invalid_agent_action",
        "required_tool_not_selected",
        "invalid_json",
        "unknown_tool",
        "tool-use limit"
      ])
  end

  defp matches?("validation", _result, _calls, text) do
    contains_any?(text, [
      "invalid_action_plan",
      "invalid_cover_target",
      "missing_device",
      "missing_capability",
      "unknown_capability",
      "not_found",
      "ambiguous"
    ])
  end

  defp matches?("policy", _result, _calls, text) do
    contains_any?(text, [
      "skill_tool_not_allowed",
      "skill_risk_exceeded",
      "retry_not_eligible",
      "conflicting_action_pending",
      "permission",
      "confirmation"
    ])
  end

  defp matches?("transport", _result, _calls, text) do
    contains_any?(text, [
      "transport_failure",
      "executor_failure",
      "mqtt",
      "action_timeout",
      "task_exit",
      "publish_failed"
    ])
  end

  defp matches?("non-convergence", _result, calls, text) do
    contains_any?(text, ["verification_timeout", "never_converges", "non_convergence"]) or
      Enum.any?(calls, &accepted_unverified?/1)
  end

  defp matches?("user-feedback", _result, _calls, text) do
    contains_any?(text, ["user_feedback", "negative_feedback", "thumbs_down"])
  end

  defp accepted_unverified?(call) when is_map(call) do
    result = Map.get(call, :result) || Map.get(call, "result") || %{}
    status = Map.get(result, :status) || Map.get(result, "status")
    verified = Map.get(result, :verified) || Map.get(result, "verified")
    status == "accepted" and verified != true
  end

  defp accepted_unverified?(_call), do: false

  defp contains_any?(text, needles), do: Enum.any?(needles, &String.contains?(text, &1))
end

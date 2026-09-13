defmodule Zaik.Home.AutonomyDecisionStoreTest do
  use ExUnit.Case, async: true

  test "retains a bounded newest decision window" do
    {:ok, store} =
      start_supervised(
        {Zaik.Home.Autonomy.DecisionStore, name: nil, db_path: ":memory:", max_rows: 2}
      )

    for index <- 1..3 do
      assert {:ok, _} =
               Zaik.Home.Autonomy.DecisionStore.record(
                 %{
                   id: "decision-#{index}",
                   mode: :shadow,
                   query: "room",
                   snapshot_id: "snapshot-#{index}",
                   status: "no_candidates",
                   context: %{},
                   candidates: [],
                   arbitration: %{},
                   reconciliation: %{},
                   policy_fingerprint: "policy",
                   created_at: "2026-01-01T00:00:0#{index}Z"
                 },
                 store
               )
    end

    assert Enum.map(Zaik.Home.Autonomy.DecisionStore.recent(10, store), & &1.id) == [
             "decision-3",
             "decision-2"
           ]

    assert {:error, :not_found} = Zaik.Home.Autonomy.DecisionStore.lookup("decision-1", store)

    assert {:ok, with_outcome} =
             Zaik.Home.Autonomy.DecisionStore.record_outcome(
               "decision-3",
               %{
                 status: "verified",
                 action_id: "action-3",
                 policy_id: "daylight_harvesting",
                 snapshot_id: "snapshot-3"
               },
               store
             )

    assert [outcome] = with_outcome.outcomes
    assert outcome["status"] == "verified"
    assert outcome["action_id"] == "action-3"
    assert is_binary(outcome["recorded_at"])

    assert {:ok, with_feedback} =
             Zaik.Home.Autonomy.DecisionStore.record_feedback(
               "decision-3",
               %{rating: 1, owner: "parent", comment: "correct"},
               store
             )

    assert [%{"rating" => 1, "owner" => "parent", "comment" => "correct"}] =
             Enum.map(with_feedback.feedback, &Map.drop(&1, ["recorded_at"]))

    assert {:error, {:invalid_autonomy_feedback, :rating_or_owner}} =
             Zaik.Home.Autonomy.DecisionStore.record_feedback(
               "decision-3",
               %{rating: 5},
               store
             )
  end
end

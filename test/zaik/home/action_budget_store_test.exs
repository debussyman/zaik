defmodule Zaik.Home.ActionBudgetStoreTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, clock} =
      start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: ~U[2026-07-15 12:00:00Z]})

    limits = %{
      device: %{max_actions: 1, window_seconds: 60},
      room: %{max_actions: 2, window_seconds: 60},
      global: %{max_actions: 3, window_seconds: 60}
    }

    {:ok, store} =
      start_supervised(
        {Zaik.Home.Autonomy.ActionBudgetStore,
         name: nil, db_path: ":memory:", clock: {Zaik.Home.Mirror.Clock, clock}, limits: limits}
      )

    %{clock: clock, limits: limits, store: store}
  end

  test "assesses device, room, and global windows without consuming budget", context do
    left = action("left")
    right = action("right")
    third = action("third")

    assert {:ok, [_]} =
             Zaik.Home.Autonomy.ActionBudgetStore.record(
               [left],
               %{decision_id: "first", scope: "room"},
               context.store
             )

    assert {:ok, assessment} =
             Zaik.Home.Autonomy.ActionBudgetStore.assess(
               [left, right],
               "room",
               [],
               context.store
             )

    assert assessment.status == "blocked"
    assert Enum.map(assessment.allowed, & &1.entity_id) == ["right"]
    assert [%{reason: "action_budget_exceeded", dimensions: dimensions}] = assessment.blocked
    assert Enum.map(dimensions, & &1.dimension) == ["device"]

    assert {:ok, batch} =
             Zaik.Home.Autonomy.ActionBudgetStore.assess(
               [right, third],
               "room",
               [],
               context.store
             )

    assert Enum.map(batch.allowed, & &1.entity_id) == ["right"]
    assert [%{dimensions: [%{dimension: "room"}]}] = batch.blocked

    assert %{room: %{current: 1}, global: %{current: 1}} =
             Zaik.Home.Autonomy.ActionBudgetStore.usage("room", [], context.store)
  end

  test "authorization atomically rejects exhausted batches and records allowed batches",
       context do
    left = action("left")
    right = action("right")

    assert {:ok, [_]} =
             Zaik.Home.Autonomy.ActionBudgetStore.record(
               [left],
               %{decision_id: "seed", scope: "room"},
               context.store
             )

    assert {:error, {:action_budget_exceeded, %{blocked: [_]}}} =
             Zaik.Home.Autonomy.ActionBudgetStore.authorize_and_record(
               [left],
               %{decision_id: "blocked", scope: "room"},
               [],
               context.store
             )

    assert {:ok, %{event_ids: [_], assessment: %{status: "allowed"}}} =
             Zaik.Home.Autonomy.ActionBudgetStore.authorize_and_record(
               [right],
               %{decision_id: "allowed", scope: "room"},
               [],
               context.store
             )

    assert %{room: %{current: 2}, global: %{current: 2}} =
             Zaik.Home.Autonomy.ActionBudgetStore.usage("room", [], context.store)
  end

  test "recording is idempotent and virtual time expires old usage", context do
    metadata = %{decision_id: "stable", scope: "room"}

    assert {:ok, [id]} =
             Zaik.Home.Autonomy.ActionBudgetStore.record(
               [action("left")],
               metadata,
               context.store
             )

    assert {:ok, [^id]} =
             Zaik.Home.Autonomy.ActionBudgetStore.record(
               [action("left")],
               metadata,
               context.store
             )

    assert %{global: %{current: 1}} =
             Zaik.Home.Autonomy.ActionBudgetStore.usage("room", [], context.store)

    Zaik.Home.Mirror.Clock.advance(context.clock, 60_001)

    assert {:ok, %{status: "allowed", allowed: [_], blocked: []}} =
             Zaik.Home.Autonomy.ActionBudgetStore.assess(
               [action("left")],
               "room",
               [],
               context.store
             )
  end

  test "rejects incomplete or unbounded budget configuration", context do
    assert {:error, :invalid_action_budget_limits} =
             Zaik.Home.Autonomy.ActionBudgetStore.assess(
               [],
               "room",
               [limits: %{device: %{max_actions: 0, window_seconds: 0}}],
               context.store
             )
  end

  defp action(entity_id) do
    %{
      entity_id: entity_id,
      device: "#{entity_id} blind",
      capability: "cover",
      target: %{"position" => 0},
      policy_id: "daylight_harvesting"
    }
  end
end

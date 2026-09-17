defmodule Zaik.Home.AutonomyScopeModeStoreTest do
  use ExUnit.Case, async: true

  setup do
    now = ~U[2026-07-15 14:00:00Z]
    {:ok, clock} = start_supervised({Zaik.Home.Mirror.Clock, name: nil, now: now})
    {:ok, bus} = start_supervised({Zaik.Home.EventBus, name: nil})

    {:ok, store} =
      start_supervised(
        {Zaik.Home.Autonomy.ScopeModeStore,
         name: nil, db_path: ":memory:", clock: {Zaik.Home.Mirror.Clock, clock}, event_bus: bus}
      )

    %{clock: clock, bus: bus, store: store}
  end

  test "resolves deterministic scope and policy precedence", context do
    assert {:ok, home} = configure(context, "home", :shadow)

    assert {:ok, policy} =
             configure(context, "home", :advisory, %{policy_id: "daylight_harvesting"})

    assert {:ok, area} = configure(context, "lily_bedroom", :off)

    assert {:ok, exact} =
             configure(context, "lily_bedroom", :shadow, %{
               policy_id: "daylight_harvesting"
             })

    assert %{
             mode: :shadow,
             precedence: "area_policy",
             rule_id: exact_id
           } = effective(context, "lily_bedroom", "daylight_harvesting")

    assert exact_id == exact.id

    assert %{mode: :off, precedence: "area", rule_id: area_id} =
             effective(context, "lily_bedroom", "solar_heat_avoidance")

    assert area_id == area.id

    assert %{mode: :advisory, precedence: "policy", rule_id: policy_id} =
             effective(context, "main_bedroom", "daylight_harvesting")

    assert policy_id == policy.id

    assert %{mode: :shadow, precedence: "home", rule_id: home_id} =
             effective(context, "main_bedroom", "solar_heat_avoidance")

    assert home_id == home.id
  end

  test "global off overrides more specific rules", context do
    assert {:ok, _exact} =
             configure(context, "lily_bedroom", :advisory, %{
               policy_id: "daylight_harvesting"
             })

    assert {:ok, global} = configure(context, "home", :off)

    assert %{mode: :off, precedence: "global_off", rule_id: id} =
             effective(context, "lily_bedroom", "daylight_harvesting")

    assert id == global.id
  end

  test "supersedes configuration, audits removal, and publishes changes", context do
    :ok = Zaik.Home.EventBus.subscribe(context.bus, self())
    assert {:ok, first} = configure(context, "lily_bedroom", :shadow)

    assert_receive {:zaik_home_event,
                    %{
                      type: :autonomy_scope_mode_changed,
                      area: "lily_bedroom",
                      mode: "shadow"
                    }}

    assert {:ok, second} = configure(context, "lily_bedroom", :off)
    assert [active] = Zaik.Home.Autonomy.ScopeModeStore.active("lily_bedroom", [], context.store)
    assert active.id == second.id

    assert {:error, {:autonomy_scope_mode_not_active, _}} =
             Zaik.Home.Autonomy.ScopeModeStore.remove(first.id, "operator", [], context.store)

    assert {:ok, removed} =
             Zaik.Home.Autonomy.ScopeModeStore.remove(second.id, "operator", [], context.store)

    assert removed.status == "removed"
    assert removed.removed_by == "operator"
    assert Zaik.Home.Autonomy.ScopeModeStore.active("lily_bedroom", [], context.store) == []
  end

  test "rejects physical execution modes and unknown policies", context do
    assert {:error, {:execution_mode_not_enabled, "canary"}} =
             configure(context, "home", :canary)

    assert {:error, {:execution_mode_not_enabled, "active"}} =
             configure(context, "home", :active)

    assert {:error, {:unknown_autonomy_policy, "invented"}} =
             configure(context, "home", :shadow, %{policy_id: "invented"})
  end

  test "uses safe runtime fallback when no rule exists", context do
    assert %{
             mode: :advisory,
             source: "runtime_default",
             precedence: "runtime_default",
             rule_id: nil
           } = effective(context, "lily_bedroom", "daylight_harvesting", :advisory)
  end

  defp configure(context, scope, mode, attrs \\ %{}) do
    Zaik.Home.Autonomy.ScopeModeStore.configure(
      scope,
      mode,
      Map.merge(%{changed_by: "test", reason: "test"}, attrs),
      [clock: {Zaik.Home.Mirror.Clock, context.clock}],
      context.store
    )
  end

  defp effective(context, scope, policy, fallback \\ :shadow) do
    Zaik.Home.Autonomy.ScopeModeStore.effective(
      scope,
      policy,
      fallback,
      [],
      context.store
    )
  end
end

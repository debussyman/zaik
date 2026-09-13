defmodule Zaik.Home.Mirror.Evals do
  @moduledoc """
  Deterministic end-to-end regression scenarios for the virtual home.
  """

  alias Zaik.Home.Mirror.{Runner, Scenarios}

  defmodule HangingPolicy do
    @behaviour Zaik.Home.Policy

    def descriptor do
      %{
        id: "mirror_hanging_policy",
        version: "1",
        description: "Mirror-only timeout policy",
        priority_class: :daylight_energy,
        priority: 40,
        dependencies: ["cover"],
        hysteresis: %{},
        minimum_active_seconds: 0,
        settle_seconds: 0,
        cooldown_seconds: 0,
        default_mode: :shadow
      }
    end

    def evaluate(_context, _opts) do
      Process.sleep(5_000)
      {:ok, []}
    end
  end

  def run do
    results = Enum.map(cases(), &run_case/1)

    %{
      passed: Enum.count(results, & &1.passed?),
      failed: Enum.count(results, &(not &1.passed?)),
      results: results
    }
  end

  def cases do
    [
      %{name: "bedtime_reaches_verified_desired_state", kind: :success},
      %{name: "invalid_plan_has_zero_side_effects", kind: :invalid},
      %{name: "later_executor_failure_reports_partial_completion", kind: :partial},
      %{name: "accepted_non_convergence_is_not_verified", kind: :stalled},
      %{name: "virtual_time_drives_expiry_and_retry_eligibility", kind: :virtual_retry},
      %{name: "production_schema_fixtures_execute_real_sql", kind: :sqlite_fixtures},
      %{name: "stale_report_does_not_regress_state", kind: :stale_report},
      %{name: "duplicate_report_is_idempotent", kind: :duplicate_report},
      %{name: "out_of_order_reports_preserve_newest_state", kind: :out_of_order_reports},
      %{name: "conflicting_pending_action_is_rejected", kind: :conflicting_actions},
      %{name: "daylight_harvesting_shadow_has_zero_side_effects", kind: :daylight_shadow},
      %{name: "manual_override_suppresses_until_virtual_expiry", kind: :manual_override},
      %{name: "occupancy_absence_requires_virtual_settle_window", kind: :occupancy_debounce},
      %{name: "goal_context_gathers_fresh_independent_evidence", kind: :goal_context},
      %{name: "generic_preset_capture_and_apply_use_mirror_executor", kind: :preset_tools},
      %{name: "explicit_action_creates_temporary_override", kind: :explicit_override},
      %{name: "operator_pause_blocks_autonomy_evaluation", kind: :operator_pause},
      %{name: "daylight_hysteresis_survives_sensor_noise", kind: :daylight_hysteresis},
      %{name: "autonomy_action_budgets_expire_under_virtual_time", kind: :action_budget},
      %{name: "autonomy_conflict_locks_follow_pending_actions", kind: :conflict_lock},
      %{name: "privacy_mode_suppresses_daylight_until_expiry", kind: :privacy_mode},
      %{name: "solar_heat_outranks_daylight_but_not_privacy", kind: :solar_heat},
      %{name: "decision_outcomes_and_feedback_are_durable", kind: :decision_feedback},
      %{name: "stuck_policy_evaluation_is_durably_timed_out", kind: :evaluation_timeout}
    ]
  end

  defp run_case(%{kind: :success} = definition) do
    scenario = Scenarios.lily_bedtime_with_ac(id: definition.name)

    finish(definition, Runner.run(scenario, &execute_bedtime/2), fn run ->
      match?({:ok, %{verified: true}}, run.result) and run.report.passed? and
        run.report.side_effect_count == 2
    end)
  end

  defp run_case(%{kind: :invalid} = definition) do
    scenario = Scenarios.lily_bedtime_with_ac(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn _mirror, context ->
        execute_plan(
          context,
          [
            action("Lily's bedroom left blind", %{"position" => 101}),
            action("Lily's bedroom right blind", %{"position" => 71})
          ],
          "invalid"
        )
      end),
      fn run ->
        match?({:error, {:invalid_action_plan, _}}, run.result) and
          run.report.side_effect_count == 0
      end
    )
  end

  defp run_case(%{kind: :partial} = definition) do
    scenario =
      Scenarios.lily_bedtime_with_ac(
        id: definition.name,
        faults: %{"Lily's bedroom right blind" => :executor_failure}
      )

    finish(definition, Runner.run(scenario, &execute_bedtime/2), fn run ->
      match?({:error, {:action_plan_failed, %{status: "partially_completed"}}}, run.result) and
        run.report.side_effect_count == 1
    end)
  end

  defp run_case(%{kind: :stalled} = definition) do
    scenario =
      Scenarios.lily_bedtime_with_ac(
        id: definition.name,
        faults: %{"Lily's bedroom left blind" => :never_converges}
      )

    finish(
      definition,
      Runner.run(scenario, fn _mirror, context ->
        Zaik.Tools.Executor.run(
          "control_device",
          action("Lily's bedroom left blind", %{"state" => "CLOSE"}),
          request_context(context, definition.name)
        )
      end),
      fn run ->
        match?({:ok, %{status: "accepted", verified: false}}, run.result) and
          not run.report.passed? and run.report.side_effect_count == 1
      end
    )
  end

  defp run_case(%{kind: :virtual_retry} = definition) do
    scenario =
      Scenarios.lily_bedtime_with_ac(
        id: definition.name,
        faults: %{
          "Lily's bedroom left blind" => %{
            type: :delayed_convergence,
            delay_ms: 100,
            reported_position: 50
          }
        },
        metadata: %{verification_timeout_ms: 50, verification_wait_ms: 0}
      )

    finish(
      definition,
      Runner.run(scenario, fn mirror, context ->
        context = request_context(context, definition.name)

        with {:ok, action} <-
               Zaik.Tools.Executor.run(
                 "control_device",
                 action("Lily's bedroom left blind", %{"state" => "CLOSE"}),
                 context
               ),
             %{fired: 2} <- Zaik.Home.Mirror.advance(mirror, 100),
             {:ok, entry} <-
               Zaik.Home.ActionLedger.lookup(action.action_id, mirror.action_ledger),
             {:ok, decision} <-
               Zaik.Home.ActionRetryPolicy.evaluate(
                 entry,
                 context,
                 settle_ms: 0,
                 cooldown_ms: 0
               ) do
          {:ok, %{decision: decision, now: Zaik.Home.Mirror.now(mirror)}}
        end
      end),
      fn run ->
        match?(
          {:ok,
           %{
             decision: %{eligible: true, reason: "fresh_state_not_converged"},
             now: ~U[2026-01-01 00:00:00.100Z]
           }},
          run.result
        )
      end
    )
  end

  defp run_case(%{kind: :sqlite_fixtures} = definition) do
    scenario = Scenarios.lily_with_history_and_telemetry(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn _mirror, context ->
        opts = context.sql_tool_opts

        with {:ok, home} <-
               Zaik.Analytics.SQLTool.run(
                 "SELECT COUNT(*) AS reading_count FROM home_readings WHERE temperature_c IS NOT NULL",
                 Keyword.merge(opts, db: :home)
               ),
             {:ok, ops} <-
               Zaik.Analytics.SQLTool.run(
                 "SELECT COUNT(*) AS message_count FROM zaik_messages",
                 Keyword.merge(opts, db: :ops)
               ) do
          {:ok, %{home: home, ops: ops}}
        end
      end),
      fn run ->
        match?(
          {:ok,
           %{
             home: %{rows: [%{"reading_count" => 3}]},
             ops: %{rows: [%{"message_count" => 2}]}
           }},
          run.result
        )
      end
    )
  end

  defp run_case(%{kind: :stale_report} = definition) do
    finish(
      definition,
      Runner.run(Scenarios.stale_report(), fn mirror, context ->
        with {:ok, action} <- execute_office(context, "stale-action", "CLOSE") do
          Zaik.Home.Mirror.advance(mirror, 10)

          %{
            status:
              Zaik.Home.ActionVerifier.status(action.action_id,
                server: mirror.action_verifier
              ),
            history_count: Zaik.Home.HistoryStore.count_readings(mirror.history_store, nil)
          }
        end
      end),
      fn run ->
        match?(
          %{status: {:ok, %{status: "pending", verified: false}}, history_count: 0},
          run.result
        ) and run.report.passed? and run.report.side_effect_count == 1 and
          Enum.map(run.report.reports, & &1.disposition) == ["stale"]
      end
    )
  end

  defp run_case(%{kind: :duplicate_report} = definition) do
    finish(
      definition,
      Runner.run(Scenarios.duplicate_report(), fn mirror, context ->
        with {:ok, action} <- execute_office(context, "duplicate-action", "CLOSE") do
          Zaik.Home.Mirror.advance(mirror, 20)

          %{
            status:
              Zaik.Home.ActionVerifier.status(action.action_id,
                server: mirror.action_verifier
              ),
            history_count: Zaik.Home.HistoryStore.count_readings(mirror.history_store, nil)
          }
        end
      end),
      fn run ->
        match?(%{status: {:ok, %{status: "verified"}}, history_count: 1}, run.result) and
          run.report.passed? and
          Enum.map(run.report.reports, & &1.disposition) == ["accepted", "duplicate"] and
          run.report.side_effect_count == 1
      end
    )
  end

  defp run_case(%{kind: :out_of_order_reports} = definition) do
    finish(
      definition,
      Runner.run(Scenarios.out_of_order_reports(), fn mirror, _context ->
        Zaik.Home.Mirror.advance(mirror, 30)
        Zaik.Home.HistoryStore.count_readings(mirror.history_store, nil)
      end),
      fn run ->
        run.result == 1 and run.report.passed? and run.report.side_effect_count == 0 and
          Enum.map(run.report.reports, & &1.disposition) == ["accepted", "stale"]
      end
    )
  end

  defp run_case(%{kind: :evaluation_timeout} = definition) do
    scenario = Scenarios.lily_with_history_and_telemetry(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn mirror, context ->
        {:ok, bus} =
          DynamicSupervisor.start_child(
            mirror.supervisor,
            {Zaik.Home.EventBus, name: nil}
          )

        {:ok, decisions} =
          DynamicSupervisor.start_child(
            mirror.supervisor,
            {Zaik.Home.Autonomy.DecisionStore,
             name: nil, db_path: mirror.home_db_path, clock: context.clock}
          )

        {:ok, engine} =
          DynamicSupervisor.start_child(
            mirror.supervisor,
            {Zaik.Home.Autonomy.Engine,
             name: nil,
             enabled: true,
             mode: :shadow,
             subscribe_events: true,
             event_bus: bus,
             event_debounce_ms: 1,
             event_min_interval_ms: 1,
             evaluation_timeout_ms: 10,
             task_supervisor: context.task_supervisor,
             clock: context.clock,
             device_store: context.device_store,
             occupancy_tracker: context.occupancy_tracker,
             history_store: context.history_store,
             decision_store: decisions,
             mode_store: context.mode_store,
             preset_store: context.preset_store,
             desired_state_store: context.desired_state_store,
             action_budget_store: context.action_budget_store,
             action_verifier: context.action_verifier,
             manual_override_store: context.manual_override_store,
             policy_registry_opts: [modules: [HangingPolicy]]}
          )

        Zaik.Home.EventBus.publish(
          %{
            type: :device_observed,
            device: "Lily's bedroom left blind",
            changed_keys: ["position"],
            observed_at: Zaik.Home.Mirror.now(mirror)
          },
          bus
        )

        Process.sleep(5)
        Zaik.Home.Mirror.advance(mirror, 1)
        Process.sleep(5)
        Zaik.Home.Mirror.advance(mirror, 10)
        Process.sleep(5)

        %{
          status: Zaik.Home.Autonomy.Engine.status(engine),
          decisions: Zaik.Home.Autonomy.DecisionStore.recent(5, decisions)
        }
      end),
      fn run ->
        run.result.status.evaluation_timeout_count == 1 and
          match?(%{status: "evaluation_timed_out"}, run.result.status.last_evaluation_failure) and
          match?([%{status: "evaluation_timed_out"} | _], run.result.decisions) and
          run.report.side_effect_count == 0
      end
    )
  end

  defp run_case(%{kind: :decision_feedback} = definition) do
    scenario = Scenarios.lily_with_history_and_telemetry(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn mirror, context ->
        {:ok, decisions} =
          DynamicSupervisor.start_child(
            mirror.supervisor,
            {Zaik.Home.Autonomy.DecisionStore,
             name: nil, db_path: mirror.home_db_path, clock: context.clock}
          )

        decision = %{
          id: "mirror-feedback-decision",
          mode: :shadow,
          query: "lily_bedroom",
          snapshot_id: "snapshot-feedback",
          status: "proposed",
          context: %{},
          candidates: [],
          arbitration: %{},
          reconciliation: %{},
          conflict_locks: %{},
          action_budget: %{},
          policy_fingerprint: "policies",
          created_at: Zaik.Home.Mirror.now(mirror)
        }

        {:ok, _stored} = Zaik.Home.Autonomy.DecisionStore.record(decision, decisions)

        {:ok, _outcome} =
          Zaik.Home.Autonomy.DecisionStore.record_outcome(
            decision.id,
            %{status: "verified", action_id: "mirror-action", snapshot_id: decision.snapshot_id},
            decisions
          )

        {:ok, updated} =
          Zaik.Home.Autonomy.DecisionStore.record_feedback(
            decision.id,
            %{rating: 1, owner: "mirror-parent", comment: "correct"},
            decisions
          )

        updated
      end),
      fn run ->
        match?([%{"status" => "verified", "action_id" => "mirror-action"}], run.result.outcomes) and
          match?([%{"rating" => 1, "owner" => "mirror-parent"}], run.result.feedback) and
          run.report.side_effect_count == 0
      end
    )
  end

  defp run_case(%{kind: :solar_heat} = definition) do
    scenario = Scenarios.lily_with_history_and_telemetry(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn mirror, context ->
        now = Zaik.Home.Mirror.now(mirror)

        Zaik.Home.DeviceStore.upsert_device(
          mirror.device_store,
          "Lily's room multi-sensor",
          %{"temperature" => 27.0, "illuminance" => 1_500, "presence" => true},
          %{"observed_at" => now, "source" => "mirror"}
        )

        for device <- ["Lily's bedroom left blind", "Lily's bedroom right blind"] do
          Zaik.Home.DeviceStore.upsert_device(
            mirror.device_store,
            device,
            %{"position" => 100},
            %{"observed_at" => now, "source" => "mirror"}
          )
        end

        for {device, position} <- [
              {"Lily's bedroom left blind", 100},
              {"Lily's bedroom right blind", 71}
            ] do
          {:ok, _preset} =
            Zaik.Home.DevicePresetStore.put(
              device,
              "solar heat",
              "cover",
              %{"position" => position},
              %{source: "mirror"},
              context.preset_store
            )
        end

        room_opts = [
          clock: context.clock,
          device_store: context.device_store,
          occupancy_tracker: context.occupancy_tracker,
          history_store: context.history_store,
          preset_store: context.preset_store,
          mode_store: context.mode_store,
          manual_override_store: context.manual_override_store,
          desired_state_store: context.desired_state_store,
          environment_config: %{utc_offset_minutes: 0}
        ]

        {:ok, hot_context} = Zaik.Home.RoomContext.build("lily", room_opts)

        {:ok, hot_candidates} =
          Zaik.Home.Policies.Registry.evaluate_all(hot_context,
            policy_opts: [
              clock: context.clock,
              maximum_temperature_f: 82.0,
              low_light_lux: 2_000
            ]
          )

        hot_arbitration = Zaik.Home.Arbitrator.arbitrate(hot_candidates, clock: context.clock)

        {:ok, _privacy} =
          Zaik.Home.Autonomy.ModeStore.activate(
            "lily_bedroom",
            "privacy",
            %{ttl_seconds: 60},
            [clock: context.clock],
            context.mode_store
          )

        {:ok, privacy_context} = Zaik.Home.RoomContext.build("lily", room_opts)

        {:ok, privacy_candidates} =
          Zaik.Home.Policies.Registry.evaluate_all(privacy_context,
            policy_opts: [
              clock: context.clock,
              maximum_temperature_f: 82.0,
              low_light_lux: 2_000
            ]
          )

        privacy_arbitration =
          Zaik.Home.Arbitrator.arbitrate(privacy_candidates, clock: context.clock)

        %{
          hot_candidates: hot_candidates,
          hot_arbitration: hot_arbitration,
          privacy_candidates: privacy_candidates,
          privacy_arbitration: privacy_arbitration
        }
      end),
      fn run ->
        Enum.any?(run.result.hot_candidates, &(&1.policy_id == "solar_heat_avoidance")) and
          Enum.all?(
            run.result.hot_arbitration.selected,
            &(&1.policy_id == "solar_heat_avoidance")
          ) and
          Enum.all?(
            run.result.privacy_arbitration.selected,
            &(&1.policy_id == "bedtime_privacy")
          ) and run.report.side_effect_count == 0
      end
    )
  end

  defp run_case(%{kind: :privacy_mode} = definition) do
    scenario = Scenarios.lily_with_history_and_telemetry(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn mirror, context ->
        now = Zaik.Home.Mirror.now(mirror)

        for device <- ["Lily's bedroom left blind", "Lily's bedroom right blind"] do
          Zaik.Home.DeviceStore.upsert_device(
            mirror.device_store,
            device,
            %{"position" => 100},
            %{"observed_at" => now, "source" => "mirror"}
          )
        end

        Zaik.Home.DeviceStore.upsert_device(
          mirror.device_store,
          "Lily's room multi-sensor",
          %{"temperature" => 22.0, "illuminance" => 15, "presence" => true},
          %{"observed_at" => now, "source" => "mirror"}
        )

        {:ok, lease} =
          Zaik.Tools.Registry.run(
            "activate_home_mode",
            %{
              "scope" => "lily",
              "mode" => "privacy",
              "ttl_seconds" => 60,
              "reason" => "privacy"
            },
            Map.put(context, :sender_id, "mirror-parent")
          )

        room_opts = [
          clock: context.clock,
          device_store: context.device_store,
          occupancy_tracker: context.occupancy_tracker,
          history_store: context.history_store,
          preset_store: context.preset_store,
          mode_store: context.mode_store,
          manual_override_store: context.manual_override_store,
          desired_state_store: context.desired_state_store,
          environment_config: %{utc_offset_minutes: 0}
        ]

        {:ok, active_context} = Zaik.Home.RoomContext.build("lily", room_opts)

        {:ok, active_candidates} =
          Zaik.Home.Policies.Registry.evaluate_all(active_context,
            policy_opts: [clock: context.clock, maximum_temperature_f: 80.0]
          )

        active_arbitration =
          Zaik.Home.Arbitrator.arbitrate(active_candidates, clock: context.clock)

        Zaik.Home.Mirror.advance(mirror, 60_000)
        {:ok, expired_context} = Zaik.Home.RoomContext.build("lily", room_opts)

        {:ok, expired_candidates} =
          Zaik.Home.Policies.Registry.evaluate_all(expired_context,
            policy_opts: [clock: context.clock, maximum_temperature_f: 80.0]
          )

        {:ok, _left_preset} =
          Zaik.Home.DevicePresetStore.put(
            "Lily's bedroom left blind",
            "bedtime",
            "cover",
            %{"position" => 100},
            %{source: "mirror"},
            context.preset_store
          )

        {:ok, _right_preset} =
          Zaik.Home.DevicePresetStore.put(
            "Lily's bedroom right blind",
            "bedtime",
            "cover",
            %{"position" => 71},
            %{source: "mirror"},
            context.preset_store
          )

        {:ok, _bedtime} =
          Zaik.Home.Autonomy.ModeStore.activate(
            "lily_bedroom",
            "bedtime",
            %{owner: "mirror-parent", reason: "sleep", ttl_seconds: 60},
            [clock: context.clock],
            context.mode_store
          )

        {:ok, bedtime_context} = Zaik.Home.RoomContext.build("lily", room_opts)

        {:ok, bedtime_candidates} =
          Zaik.Home.Policies.Registry.evaluate_all(bedtime_context,
            policy_opts: [clock: context.clock, maximum_temperature_f: 80.0]
          )

        bedtime_candidate =
          Enum.find(bedtime_candidates, &(&1.policy_id == "bedtime_privacy"))

        %{
          lease: lease,
          active_context: active_context,
          active_candidates: active_candidates,
          active_arbitration: active_arbitration,
          expired_context: expired_context,
          expired_candidates: expired_candidates,
          bedtime_candidate: bedtime_candidate
        }
      end),
      fn run ->
        Enum.map(run.result.active_candidates, & &1.policy_id) |> Enum.sort() ==
          ["bedtime_privacy", "daylight_harvesting"] and
          Enum.all?(run.result.active_arbitration.selected, &(&1.policy_id == "bedtime_privacy")) and
          Enum.all?(
            run.result.active_arbitration.suppressed,
            &(&1.reason == "conflicting_lower_priority")
          ) and run.result.expired_context.home_modes == [] and
          Enum.map(run.result.expired_candidates, & &1.policy_id) == ["daylight_harvesting"] and
          Enum.map(run.result.bedtime_candidate.desired_state, & &1.target) == [
            %{"position" => 100},
            %{"position" => 71}
          ] and run.report.side_effect_count == 0
      end
    )
  end

  defp run_case(%{kind: :conflict_lock} = definition) do
    scenario = Scenarios.lily_with_history_and_telemetry(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn mirror, context ->
        {:ok, _registered} =
          Zaik.Home.ActionVerifier.register(
            "mirror-pending-close",
            "Lily's bedroom left blind",
            "cover",
            %{"position" => 100},
            server: context.action_verifier,
            timeout_ms: 1_000
          )

        {:ok, _pending} =
          Zaik.Home.ActionVerifier.published(
            "mirror-pending-close",
            server: context.action_verifier
          )

        actions = [
          %{
            entity_id: "eval-left",
            device: "Lily's bedroom left blind",
            capability: "cover",
            target: %{"position" => 0}
          },
          %{
            entity_id: "eval-right",
            device: "Lily's bedroom right blind",
            capability: "cover",
            target: %{"position" => 0}
          }
        ]

        blocked =
          Zaik.Home.Autonomy.ConflictLock.assess(
            actions,
            Zaik.Home.ActionVerifier.pending(server: context.action_verifier),
            clock: context.clock
          )

        Zaik.Home.Mirror.advance(mirror, 1_000)

        clear =
          Zaik.Home.Autonomy.ConflictLock.assess(
            actions,
            Zaik.Home.ActionVerifier.pending(server: context.action_verifier),
            clock: context.clock
          )

        %{blocked: blocked, clear: clear}
      end),
      fn run ->
        run.result.blocked.status == "blocked" and
          match?(
            [%{reason: "conflicting_action_pending", pending_action_id: "mirror-pending-close"}],
            run.result.blocked.blocked
          ) and length(run.result.blocked.allowed) == 1 and run.result.clear.status == "clear" and
          length(run.result.clear.allowed) == 2 and run.report.side_effect_count == 0
      end
    )
  end

  defp run_case(%{kind: :action_budget} = definition) do
    scenario = Scenarios.lily_with_history_and_telemetry(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn mirror, context ->
        left = %{entity_id: "eval-left", capability: "cover"}
        right = %{entity_id: "eval-right", capability: "cover"}

        for decision_id <- ["mirror-budget-one", "mirror-budget-two"] do
          {:ok, _ids} =
            Zaik.Home.Autonomy.ActionBudgetStore.record(
              [left],
              %{decision_id: decision_id, scope: "lily_bedroom"},
              context.action_budget_store
            )
        end

        {:ok, blocked} =
          Zaik.Home.Autonomy.ActionBudgetStore.assess(
            [left, right],
            "lily_bedroom",
            [],
            context.action_budget_store
          )

        Zaik.Home.Mirror.advance(mirror, 900_001)

        {:ok, expired} =
          Zaik.Home.Autonomy.ActionBudgetStore.assess(
            [left, right],
            "lily_bedroom",
            [],
            context.action_budget_store
          )

        %{blocked: blocked, expired: expired}
      end),
      fn run ->
        run.result.blocked.status == "blocked" and
          Enum.map(run.result.blocked.allowed, & &1.entity_id) == ["eval-right"] and
          run.result.expired.status == "allowed" and length(run.result.expired.allowed) == 2 and
          run.report.side_effect_count == 0
      end
    )
  end

  defp run_case(%{kind: :daylight_hysteresis} = definition) do
    scenario = Scenarios.lily_with_history_and_telemetry(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn mirror, context ->
        now = Zaik.Home.Mirror.now(mirror)

        for device <- ["Lily's bedroom left blind", "Lily's bedroom right blind"] do
          Zaik.Home.DeviceStore.upsert_device(
            mirror.device_store,
            device,
            %{"position" => 100},
            %{"observed_at" => now, "source" => "mirror"}
          )
        end

        Zaik.Home.DeviceStore.upsert_device(
          mirror.device_store,
          "Lily's room multi-sensor",
          %{"temperature" => 22.0, "illuminance" => 15, "presence" => true},
          %{"observed_at" => now, "source" => "mirror"}
        )

        {:ok, decisions} =
          DynamicSupervisor.start_child(
            mirror.supervisor,
            {Zaik.Home.Autonomy.DecisionStore, name: nil, db_path: ":memory:"}
          )

        {:ok, engine} =
          DynamicSupervisor.start_child(
            mirror.supervisor,
            {Zaik.Home.Autonomy.Engine,
             name: nil, enabled: true, mode: :shadow, subscribe_events: false}
          )

        opts = [
          clock: context.clock,
          device_store: context.device_store,
          occupancy_tracker: context.occupancy_tracker,
          history_store: context.history_store,
          decision_store: decisions,
          desired_state_store: context.desired_state_store,
          action_budget_store: context.action_budget_store,
          action_verifier: context.action_verifier,
          manual_override_store: context.manual_override_store,
          environment_config: %{utc_offset_minutes: 0},
          max_state_age_seconds: 600,
          policy_opts: [maximum_temperature_f: 80.0, release_maximum_temperature_f: 82.0]
        ]

        {:ok, settling} = Zaik.Home.Autonomy.Engine.evaluate("lily", opts, engine)
        Zaik.Home.Mirror.advance(mirror, 30_000)
        {:ok, activated} = Zaik.Home.Autonomy.Engine.evaluate("lily", opts, engine)
        converged_at = Zaik.Home.Mirror.now(mirror)

        for device <- ["Lily's bedroom left blind", "Lily's bedroom right blind"] do
          Zaik.Home.DeviceStore.upsert_device(
            mirror.device_store,
            device,
            %{"position" => 0},
            %{"observed_at" => converged_at, "source" => "mirror"}
          )
        end

        Zaik.Home.DeviceStore.upsert_device(
          mirror.device_store,
          "Lily's room multi-sensor",
          %{"illuminance" => 200},
          %{"observed_at" => converged_at, "source" => "mirror"}
        )

        {:ok, minimum_hold} = Zaik.Home.Autonomy.Engine.evaluate("lily", opts, engine)
        Zaik.Home.Mirror.advance(mirror, 61_000)
        {:ok, released} = Zaik.Home.Autonomy.Engine.evaluate("lily", opts, engine)

        Zaik.Home.Mirror.advance(mirror, 59_000)
        cooldown_at = Zaik.Home.Mirror.now(mirror)

        for device <- ["Lily's bedroom left blind", "Lily's bedroom right blind"] do
          Zaik.Home.DeviceStore.upsert_device(
            mirror.device_store,
            device,
            %{"position" => 100},
            %{"observed_at" => cooldown_at, "source" => "mirror"}
          )
        end

        Zaik.Home.DeviceStore.upsert_device(
          mirror.device_store,
          "Lily's room multi-sensor",
          %{"illuminance" => 15},
          %{"observed_at" => cooldown_at, "source" => "mirror"}
        )

        {:ok, cooldown} = Zaik.Home.Autonomy.Engine.evaluate("lily", opts, engine)
        Zaik.Home.Mirror.advance(mirror, 120_000)
        {:ok, resettling} = Zaik.Home.Autonomy.Engine.evaluate("lily", opts, engine)
        Zaik.Home.Mirror.advance(mirror, 30_000)
        {:ok, reactivated} = Zaik.Home.Autonomy.Engine.evaluate("lily", opts, engine)

        %{
          settling: settling,
          activated: activated,
          minimum_hold: minimum_hold,
          released: released,
          cooldown: cooldown,
          resettling: resettling,
          reactivated: reactivated
        }
      end),
      fn run ->
        run.result.settling.status == "blocked" and run.result.activated.status == "proposed" and
          hd(run.result.minimum_hold.candidates).evidence.minimum_hold == true and
          run.result.released.status == "no_candidates" and
          Enum.all?(run.result.cooldown.reconciliation.blocked, &(&1.reason == "policy_cooldown")) and
          Enum.all?(
            run.result.resettling.reconciliation.blocked,
            &(&1.reason == "policy_settling")
          ) and
          run.result.reactivated.status == "proposed" and run.report.side_effect_count == 0
      end
    )
  end

  defp run_case(%{kind: :operator_pause} = definition) do
    scenario = Scenarios.lily_with_history_and_telemetry(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn mirror, context ->
        {:ok, engine} =
          DynamicSupervisor.start_child(
            mirror.supervisor,
            {Zaik.Home.Autonomy.Engine,
             name: nil,
             enabled: true,
             mode: :shadow,
             subscribe_events: false,
             event_bus: false,
             task_supervisor: context.task_supervisor,
             clock: context.clock,
             desired_state_store: context.desired_state_store,
             action_budget_store: context.action_budget_store,
             action_verifier: context.action_verifier,
             manual_override_store: context.manual_override_store}
          )

        pause = Zaik.Home.Autonomy.Engine.pause("mirror maintenance", "operator", engine)
        blocked = Zaik.Home.Autonomy.Engine.evaluate("lily", [], engine)
        active = Zaik.Home.Autonomy.Engine.set_mode(:active, "operator", engine)
        advisory = Zaik.Home.Autonomy.Engine.set_mode(:advisory, "operator", engine)
        resumed = Zaik.Home.Autonomy.Engine.resume("operator", engine)

        %{
          pause: pause,
          blocked: blocked,
          active: active,
          advisory: advisory,
          resumed: resumed,
          status: Zaik.Home.Autonomy.Engine.status(engine)
        }
      end),
      fn run ->
        match?({:ok, %{reason: "mirror maintenance"}}, run.result.pause) and
          match?({:error, {:autonomy_paused, _}}, run.result.blocked) and
          run.result.active == {:error, {:execution_mode_not_enabled, :active}} and
          run.result.advisory == {:ok, :advisory} and run.result.status.paused == false and
          run.result.status.mode == :advisory and run.report.side_effect_count == 0
      end
    )
  end

  defp run_case(%{kind: :explicit_override} = definition) do
    scenario = Scenarios.lily_bedtime_with_ac(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn _mirror, context ->
        result =
          Zaik.Tools.Executor.run(
            "apply_device_preset",
            %{
              "device" => "Lily's bedroom right blind",
              "capability" => "cover",
              "preset" => "above AC"
            },
            Map.merge(context, %{
              channel: :telegram,
              chat_id: "mirror-chat",
              message_id: "explicit-preset",
              sender_id: "mirror-user"
            }),
            task_supervisor: context.task_supervisor,
            ledger: context.action_ledger
          )

        overrides =
          Zaik.Home.Autonomy.ManualOverrideStore.active(
            "lily_bedroom",
            [clock: context.clock],
            context.manual_override_store
          )

        %{action: result, overrides: overrides}
      end),
      fn run ->
        match?({:ok, %{target: %{"position" => 71}}}, run.result.action) and
          match?([%{owner: "mirror-user", capability: "cover"}], run.result.overrides) and
          run.report.side_effect_count == 1
      end
    )
  end

  defp run_case(%{kind: :preset_tools} = definition) do
    scenario = Scenarios.lily_bedtime_with_ac(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn mirror, context ->
        args = %{
          "device" => "Lily's bedroom right blind",
          "capability" => "cover",
          "preset" => "captured open"
        }

        {:ok, captured} =
          Zaik.Home.Tools.CaptureDevicePreset.run(args, Map.put(context, :sender_id, "mirror"))

        Zaik.Home.DeviceStore.upsert_device(
          mirror.device_store,
          "Lily's bedroom right blind",
          %{"position" => 100},
          %{"observed_at" => Zaik.Home.Mirror.now(mirror), "source" => "mirror"}
        )

        applied =
          Zaik.Home.Tools.ApplyDevicePreset.run(
            args,
            Map.put(context, :action_id, "mirror-preset-apply")
          )

        %{captured: captured, applied: applied}
      end),
      fn run ->
        run.result.captured["target"] == %{"position" => 0} and
          match?({:ok, %{target: %{"position" => 0}}}, run.result.applied) and
          run.report.side_effect_count == 1
      end
    )
  end

  defp run_case(%{kind: :goal_context} = definition) do
    scenario = Scenarios.lily_with_history_and_telemetry(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn _mirror, context ->
        skill = %{
          risk: "low",
          allowed_tools: ["execute_home_plan"],
          contract: %{
            schema_version: 1,
            goal_id: "lily_bedtime",
            scope: "lily_bedroom",
            required_observations: [
              "environment.solar_phase",
              "environment.season",
              "history.temperature_f",
              "capability.cover",
              "presets.cover"
            ],
            preferences: ["preserve cooling airflow"],
            constraints: ["right blind uses above AC"],
            allowed_tools: ["execute_home_plan"],
            risk_ceiling: "low",
            missing_data_policy: "block"
          }
        }

        Zaik.Home.GoalContextBuilder.build(skill,
          clock: context.clock,
          device_store: context.device_store,
          occupancy_tracker: context.occupancy_tracker,
          history_store: context.history_store,
          manual_override_store: context.manual_override_store,
          desired_state_store: context.desired_state_store,
          preset_store: context.preset_store,
          environment_config: %{utc_offset_minutes: 0}
        )
      end),
      fn run ->
        match?(
          {:ok,
           %{
             goal_id: "lily_bedtime",
             status: "ready",
             missing: [],
             presets: [_ | _]
           }},
          run.result
        ) and run.report.side_effect_count == 0
      end
    )
  end

  defp run_case(%{kind: :occupancy_debounce} = definition) do
    scenario = Scenarios.lily_with_history_and_telemetry(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn mirror, context ->
        {:ok, bus} =
          DynamicSupervisor.start_child(
            mirror.supervisor,
            {Zaik.Home.EventBus, name: nil}
          )

        {:ok, tracker} =
          DynamicSupervisor.start_child(
            mirror.supervisor,
            {Zaik.Home.OccupancyTracker,
             name: nil, event_bus: bus, clock: context.clock, absence_debounce_ms: 60_000}
          )

        publish_presence(bus, true, Zaik.Home.Mirror.now(mirror))
        sync_processes(bus, tracker)
        entered = Zaik.Home.OccupancyTracker.status("lily_bedroom", tracker)

        publish_presence(bus, false, Zaik.Home.Mirror.now(mirror))
        sync_processes(bus, tracker)
        possibly_absent = Zaik.Home.OccupancyTracker.status("lily_bedroom", tracker)

        Zaik.Home.Mirror.advance(mirror, 59_999)
        before_expiry = Zaik.Home.OccupancyTracker.status("lily_bedroom", tracker)
        Zaik.Home.Mirror.advance(mirror, 1)
        :sys.get_state(tracker)
        vacant = Zaik.Home.OccupancyTracker.status("lily_bedroom", tracker)

        %{
          entered: entered,
          possibly_absent: possibly_absent,
          before_expiry: before_expiry,
          vacant: vacant
        }
      end),
      fn run ->
        run.result.entered.transition == "entered" and
          run.result.possibly_absent.status == "possibly_absent" and
          run.result.before_expiry.status == "possibly_absent" and
          run.result.vacant.transition == "vacant" and run.report.side_effect_count == 0
      end
    )
  end

  defp run_case(%{kind: :manual_override} = definition) do
    scenario = Scenarios.lily_with_history_and_telemetry(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn mirror, context ->
        now = Zaik.Home.Mirror.now(mirror)

        for device <- ["Lily's bedroom left blind", "Lily's bedroom right blind"] do
          Zaik.Home.DeviceStore.upsert_device(
            mirror.device_store,
            device,
            %{"position" => 100},
            %{"observed_at" => now, "source" => "mirror"}
          )
        end

        Zaik.Home.DeviceStore.upsert_device(
          mirror.device_store,
          "Lily's room multi-sensor",
          %{"temperature" => 22.0, "illuminance" => 15, "presence" => true},
          %{"observed_at" => now, "source" => "mirror"}
        )

        {:ok, lease} =
          Zaik.Home.Autonomy.ManualOverrideStore.create(
            "lily_bedroom",
            %{owner: "mirror-user", reason: "manual close", ttl_seconds: 60},
            [clock: context.clock],
            context.manual_override_store
          )

        room_opts = [
          clock: context.clock,
          device_store: context.device_store,
          occupancy_tracker: context.occupancy_tracker,
          history_store: context.history_store,
          manual_override_store: context.manual_override_store,
          environment_config: %{utc_offset_minutes: 0},
          history_capabilities: ["temperature_f"]
        ]

        {:ok, before_context} = Zaik.Home.RoomContext.build("lily", room_opts)

        {:ok, before_candidates} =
          Zaik.Home.Policies.DaylightHarvesting.evaluate(before_context,
            clock: context.clock,
            maximum_temperature_f: 80.0
          )

        Zaik.Home.Mirror.advance(mirror, 60_000)
        {:ok, after_context} = Zaik.Home.RoomContext.build("lily", room_opts)

        {:ok, after_candidates} =
          Zaik.Home.Policies.DaylightHarvesting.evaluate(after_context,
            clock: context.clock,
            maximum_temperature_f: 80.0
          )

        %{lease: lease, before: before_candidates, after: after_candidates}
      end),
      fn run ->
        run.result.before == [] and length(run.result.after) == 1 and
          run.report.side_effect_count == 0
      end
    )
  end

  defp run_case(%{kind: :daylight_shadow} = definition) do
    scenario = Scenarios.lily_with_history_and_telemetry(id: definition.name)

    finish(
      definition,
      Runner.run(scenario, fn mirror, context ->
        now = Zaik.Home.Mirror.now(mirror)

        for device <- ["Lily's bedroom left blind", "Lily's bedroom right blind"] do
          Zaik.Home.DeviceStore.upsert_device(
            mirror.device_store,
            device,
            %{"position" => 100},
            %{"observed_at" => now, "source" => "mirror"}
          )
        end

        Zaik.Home.DeviceStore.upsert_device(
          mirror.device_store,
          "Lily's room multi-sensor",
          %{"temperature" => 22.0, "illuminance" => 15, "presence" => true},
          %{"observed_at" => now, "source" => "mirror"}
        )

        {:ok, decision_store} =
          DynamicSupervisor.start_child(
            mirror.supervisor,
            {Zaik.Home.Autonomy.DecisionStore, name: nil, db_path: ":memory:"}
          )

        {:ok, engine} =
          DynamicSupervisor.start_child(
            mirror.supervisor,
            {Zaik.Home.Autonomy.Engine, name: nil, enabled: true, mode: :shadow}
          )

        evaluation_opts = [
          clock: context.clock,
          device_store: context.device_store,
          occupancy_tracker: context.occupancy_tracker,
          history_store: context.history_store,
          decision_store: decision_store,
          desired_state_store: context.desired_state_store,
          action_budget_store: context.action_budget_store,
          action_verifier: context.action_verifier,
          manual_override_store: context.manual_override_store,
          environment_config: %{utc_offset_minutes: 0},
          policy_opts: [maximum_temperature_f: 80.0]
        ]

        settling = Zaik.Home.Autonomy.Engine.evaluate("lily", evaluation_opts, engine)
        Zaik.Home.Mirror.advance(mirror, 30_000)
        decision = Zaik.Home.Autonomy.Engine.evaluate("lily", evaluation_opts, engine)

        desired =
          Zaik.Home.Autonomy.DesiredStateStore.active(
            "lily_bedroom",
            [clock: context.clock],
            context.desired_state_store
          )

        %{settling: settling, decision: decision, desired: desired}
      end),
      fn run ->
        match?(
          {:ok, %{status: "blocked", reconciliation: %{blocked: [_, _]}}},
          run.result.settling
        ) and
          match?(
            {:ok,
             %{
               mode: :shadow,
               status: "proposed",
               candidates: [%{confidence: 0.7}],
               reconciliation: %{actions: [_, _]}
             }},
            run.result.decision
          ) and length(run.result.desired) == 2 and run.report.side_effect_count == 0
      end
    )
  end

  defp run_case(%{kind: :conflicting_actions} = definition) do
    finish(
      definition,
      Runner.run(Scenarios.conflicting_actions(), fn mirror, context ->
        with {:ok, first} <- execute_office(context, "conflict-close", "CLOSE") do
          second = execute_office(context, "conflict-open", "OPEN")
          Zaik.Home.Mirror.advance(mirror, 10)

          first_status =
            Zaik.Home.ActionVerifier.status(first.action_id, server: mirror.action_verifier)

          %{second: second, first_status: first_status}
        end
      end),
      fn run ->
        match?(
          %{
            second: {:error, {:conflicting_action_pending, _action_id}},
            first_status: {:ok, %{status: "verified"}}
          },
          run.result
        ) and run.report.passed? and run.report.side_effect_count == 1
      end
    )
  end

  defp execute_office(context, message_id, state) do
    Zaik.Tools.Executor.run(
      "control_device",
      action("Office blind", %{"state" => state}),
      request_context(context, message_id)
    )
  end

  defp execute_bedtime(_mirror, context) do
    execute_plan(
      context,
      [
        action("Lily's bedroom left blind", %{"state" => "CLOSE"}),
        action("Lily's bedroom right blind", %{"preset" => "above AC"})
      ],
      "bedtime"
    )
  end

  defp execute_plan(context, actions, suffix) do
    Zaik.Tools.Executor.run(
      "execute_home_plan",
      %{"goal" => "Lily bedtime with AC", "actions" => actions},
      request_context(context, suffix)
    )
  end

  defp request_context(context, message_id) do
    Map.merge(context, %{channel: :mirror, chat_id: "mirror-eval", message_id: message_id})
  end

  defp action(device, target) do
    %{"device" => device, "capability" => "cover", "target" => target}
  end

  defp publish_presence(bus, detected, observed_at) do
    Zaik.Home.EventBus.publish(
      %{
        type: :device_observed,
        device: "mirror-presence",
        payload: %{"presence" => detected},
        metadata: %{"area_id" => "lily_bedroom"},
        changed_keys: ["presence"],
        observed_at: observed_at
      },
      bus
    )
  end

  defp sync_processes(bus, tracker) do
    :sys.get_state(bus)
    :sys.get_state(tracker)
  end

  defp finish(definition, {:ok, run}, predicate) do
    %{
      name: definition.name,
      passed?: predicate.(run),
      result: run.result,
      report: run.report
    }
  end

  defp finish(definition, {:error, reason}, _predicate) do
    %{name: definition.name, passed?: false, result: {:error, reason}, report: nil}
  end
end

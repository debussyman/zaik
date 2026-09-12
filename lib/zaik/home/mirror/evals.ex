defmodule Zaik.Home.Mirror.Evals do
  @moduledoc """
  Deterministic end-to-end regression scenarios for the virtual home.
  """

  alias Zaik.Home.Mirror.{Runner, Scenarios}

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
      %{name: "generic_preset_capture_and_apply_use_mirror_executor", kind: :preset_tools}
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

        Zaik.Home.Autonomy.Engine.evaluate(
          "lily",
          [
            clock: context.clock,
            device_store: context.device_store,
            occupancy_tracker: context.occupancy_tracker,
            history_store: context.history_store,
            decision_store: decision_store,
            manual_override_store: context.manual_override_store,
            environment_config: %{utc_offset_minutes: 0},
            policy_opts: [maximum_temperature_f: 80.0]
          ],
          engine
        )
      end),
      fn run ->
        match?(
          {:ok,
           %{
             mode: :shadow,
             status: "proposed",
             candidates: [%{confidence: 0.7}],
             reconciliation: %{actions: [_, _]}
           }},
          run.result
        ) and run.report.side_effect_count == 0
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

defmodule Zaik.Home.StagedPlanCoordinator do
  @moduledoc """
  Supervised, restart-safe coordinator for staged plans in the mirror only.

  The coordinator refuses every binding except `Zaik.Home.Mirror.Executor` with
  an isolated mirror context. Production staged execution remains unavailable.
  Each completed stage is protected by the action ledger and durably
  checkpointed before the next stage is considered.
  """

  @default_timeout_ms 30_000
  @verification_timeout_seconds 120
  @verification_poll_seconds 2

  def run(plan_id, context, opts \\ []) when is_binary(plan_id) and is_map(context) do
    with :ok <- mirror_binding(context),
         {:ok, supervisor} <- task_supervisor(context, opts) do
      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          lock = {{__MODULE__, plan_id}, self()}

          case :global.trans(lock, fn -> coordinate(plan_id, context, opts) end, [node()], 0) do
            :aborted -> {:error, :staged_plan_already_running}
            {:aborted, _reason} -> {:error, :staged_plan_already_running}
            result -> result
          end
        end)

      timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:staged_plan_coordinator_exit, reason}}
        nil -> {:error, :staged_plan_coordinator_timeout}
      end
    end
  end

  defp coordinate(plan_id, context, opts) do
    store = setting(context, :staged_plan_store)
    runner_id = "mirror:#{setting(context, :mirror_scenario_id)}:#{plan_id}"
    clock_opts = [clock: setting(context, :clock)]

    with {:ok, run} <- Zaik.Home.StagedPlanStore.claim_run(plan_id, runner_id, clock_opts, store) do
      stages = get_in(run, [:plan, "stages"]) || []

      if cancellation_requested?(run) and run.current_stage < length(stages) do
        cancel_requested_run(run, runner_id, context)
      else
        execute_stages(run, stages, run.current_stage, runner_id, context, opts)
      end
    end
  end

  defp execute_stages(run, stages, index, runner_id, context, _opts)
       when index >= length(stages) do
    result = %{
      status: "completed",
      completed_stages: length(stages),
      stage_results: run.stage_results
    }

    case Zaik.Home.StagedPlanStore.finish(
           run.id,
           runner_id,
           result,
           [clock: setting(context, :clock)],
           setting(context, :staged_plan_store)
         ) do
      {:ok, completed} -> {:ok, public_result(completed)}
      error -> error
    end
  end

  defp execute_stages(run, stages, index, runner_id, context, opts) do
    stage = Enum.at(stages, index)

    with {:ok, latest} <-
           Zaik.Home.StagedPlanStore.lookup(
             run.id,
             [clock: setting(context, :clock)],
             setting(context, :staged_plan_store)
           ),
         :ok <- still_owned?(latest, runner_id) do
      if cancellation_requested?(latest) do
        cancel_requested_run(latest, runner_id, context)
      else
        with {:ok, condition_result} <- evaluate_conditions(stage, context) do
          if condition_result.matched do
            execute_stage(
              latest,
              stages,
              index,
              stage,
              condition_result,
              runner_id,
              context,
              opts
            )
          else
            handle_unmatched(latest, index, stage, condition_result, runner_id, context)
          end
        end
      end
    end
  end

  defp execute_stage(run, stages, index, stage, condition_result, runner_id, context, opts) do
    with {:ok, latest} <-
           Zaik.Home.StagedPlanStore.lookup(
             run.id,
             [clock: setting(context, :clock)],
             setting(context, :staged_plan_store)
           ),
         :ok <- still_owned?(latest, runner_id) do
      if cancellation_requested?(latest) do
        cancel_requested_run(latest, runner_id, context)
      else
        do_execute_stage(
          latest,
          stages,
          index,
          stage,
          condition_result,
          runner_id,
          context,
          opts
        )
      end
    end
  end

  defp do_execute_stage(run, stages, index, stage, condition_result, runner_id, context, opts) do
    args = %{"goal" => run.goal, "actions" => Map.get(stage, "actions", [])}

    stage_context =
      context
      |> Map.put(:channel, :mirror_staged_plan)
      |> Map.put(:chat_id, run.id)
      |> Map.put(:message_id, "stage-#{index}")

    result =
      Zaik.Tools.Executor.run_action(
        "execute_home_plan",
        args,
        stage_context,
        fn action_context ->
          Zaik.Home.ActionPlan.run(
            "#{run.goal || "staged plan"} / #{Map.get(stage, "id", index)}",
            Map.get(stage, "actions", []),
            action_context,
            executor_opts: setting(context, :executor_opts)
          )
        end,
        ledger: setting(context, :action_ledger),
        task_supervisor: setting(context, :task_supervisor),
        timeout_ms: Keyword.get(opts, :stage_timeout_ms, @default_timeout_ms)
      )

    checkpoint_result = %{
      stage_id: Map.get(stage, "id"),
      stage_index: index,
      conditions: condition_result,
      action_result: normalize_result(result)
    }

    case result do
      {:ok, report} ->
        if map_value(report, :verified) == true do
          with {:ok, checkpointed} <-
                 Zaik.Home.StagedPlanStore.checkpoint(
                   run.id,
                   runner_id,
                   index + 1,
                   checkpoint_result,
                   :running,
                   [clock: setting(context, :clock)],
                   setting(context, :staged_plan_store)
                 ) do
            execute_stages(checkpointed, stages, index + 1, runner_id, context, opts)
          end
        else
          handle_unverified_stage(
            run,
            index,
            checkpoint_result,
            runner_id,
            context
          )
        end

      {:error, reason} ->
        terminal = Map.put(checkpoint_result, :reason, inspect(reason))

        with {:ok, failed} <-
               Zaik.Home.StagedPlanStore.stop_run(
                 run.id,
                 runner_id,
                 :failed,
                 terminal,
                 [clock: setting(context, :clock)],
                 setting(context, :staged_plan_store)
               ) do
          {:error, {:staged_plan_failed, public_result(failed)}}
        end
    end
  end

  defp handle_unverified_stage(run, index, checkpoint_result, runner_id, context) do
    result =
      checkpoint_result
      |> Map.put(:waiting_kind, "verification")
      |> Map.put(:wait, %{
        timeout_seconds: @verification_timeout_seconds,
        poll_interval_seconds: @verification_poll_seconds
      })

    if verification_wait_expired?(run, context) do
      terminal = Map.put(result, :reason, "stage_verification_timeout")

      with {:ok, failed} <-
             Zaik.Home.StagedPlanStore.stop_run(
               run.id,
               runner_id,
               :failed,
               terminal,
               [clock: setting(context, :clock)],
               setting(context, :staged_plan_store)
             ) do
        {:error, {:staged_plan_failed, public_result(failed)}}
      end
    else
      with {:ok, waiting} <-
             Zaik.Home.StagedPlanStore.checkpoint(
               run.id,
               runner_id,
               index,
               result,
               :waiting,
               [clock: setting(context, :clock)],
               setting(context, :staged_plan_store)
             ) do
        {:ok, public_result(waiting)}
      end
    end
  end

  defp handle_unmatched(run, index, stage, conditions, runner_id, context) do
    result = %{
      stage_id: Map.get(stage, "id"),
      stage_index: index,
      conditions: conditions,
      wait: Map.get(stage, "wait"),
      waiting_kind: "condition"
    }

    if is_map(Map.get(stage, "wait")) do
      if wait_expired?(run, index, stage, context) do
        with {:ok, cancelled} <-
               Zaik.Home.StagedPlanStore.stop_run(
                 run.id,
                 runner_id,
                 :cancelled,
                 Map.put(result, :reason, "condition_wait_timeout"),
                 [clock: setting(context, :clock)],
                 setting(context, :staged_plan_store)
               ) do
          {:ok, public_result(cancelled)}
        end
      else
        with {:ok, waiting} <-
               Zaik.Home.StagedPlanStore.checkpoint(
                 run.id,
                 runner_id,
                 index,
                 result,
                 :waiting,
                 [clock: setting(context, :clock)],
                 setting(context, :staged_plan_store)
               ) do
          {:ok, public_result(waiting)}
        end
      end
    else
      with {:ok, cancelled} <-
             Zaik.Home.StagedPlanStore.stop_run(
               run.id,
               runner_id,
               :cancelled,
               Map.put(result, :reason, "condition_false"),
               [clock: setting(context, :clock)],
               setting(context, :staged_plan_store)
             ) do
        {:ok, public_result(cancelled)}
      end
    end
  end

  defp cancel_requested_run(run, runner_id, context) do
    result = %{
      reason: "operator_cancellation_requested",
      cancelled_by: run.cancellation_requested_by,
      cancellation_reason: run.cancellation_request_reason,
      current_stage: run.current_stage
    }

    with {:ok, cancelled} <-
           Zaik.Home.StagedPlanStore.stop_run(
             run.id,
             runner_id,
             :cancelled,
             result,
             [clock: setting(context, :clock)],
             setting(context, :staged_plan_store)
           ) do
      {:ok, public_result(cancelled)}
    end
  end

  defp cancellation_requested?(run), do: is_binary(run.cancellation_requested_at)

  defp evaluate_conditions(stage, context) do
    inputs = Map.get(stage, "conditions", [])

    results =
      Enum.map(inputs, fn input ->
        input = Map.put(input, "value", Map.get(input, "expected"))

        with {:ok, condition} <- Zaik.Home.ActionPlan.Condition.preflight(input, context),
             {:ok, evaluation} <- Zaik.Home.ActionPlan.Condition.evaluate(condition, context) do
          {:ok, evaluation}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        evaluations = Enum.map(results, fn {:ok, evaluation} -> evaluation end)
        mode = Map.get(stage, "condition_mode", "all")

        matched =
          case {mode, evaluations} do
            {_mode, []} -> true
            {"all", values} -> Enum.all?(values, & &1.matched)
            {"any", values} -> Enum.any?(values, & &1.matched)
          end

        {:ok, %{mode: mode, matched: matched, evaluations: evaluations}}
    end
  end

  defp verification_wait_expired?(%{waiting_kind: "verification"} = run, context) do
    with started_at when is_binary(started_at) <- run.waiting_since,
         {:ok, started_at, _offset} <- DateTime.from_iso8601(started_at) do
      DateTime.diff(Zaik.Time.now(setting(context, :clock)), started_at, :second) >=
        @verification_timeout_seconds
    else
      _ -> false
    end
  end

  defp verification_wait_expired?(_run, _context), do: false

  defp wait_expired?(run, _index, stage, context) do
    timeout = get_in(stage, ["wait", "timeout_seconds"])

    started_at = run.waiting_since

    with timeout when is_integer(timeout) <- timeout,
         started_at when is_binary(started_at) <- started_at,
         {:ok, started_at, _offset} <- DateTime.from_iso8601(started_at) do
      DateTime.diff(Zaik.Time.now(setting(context, :clock)), started_at, :second) >= timeout
    else
      _ -> false
    end
  end

  defp mirror_binding(context) do
    executor_opts = setting(context, :executor_opts) || []
    modules = executor_opts |> Keyword.get(:modules, []) |> List.wrap()

    cond do
      not is_binary(setting(context, :mirror_scenario_id)) ->
        {:error, :staged_plan_execution_not_enabled}

      modules == [] or not Enum.all?(modules, &(&1 == Zaik.Home.Mirror.Executor)) ->
        {:error, :staged_plan_execution_not_enabled}

      not alive_pid?(setting(context, :mirror_store)) ->
        {:error, :staged_plan_execution_not_enabled}

      not alive_pid?(setting(context, :staged_plan_store)) ->
        {:error, :staged_plan_execution_not_enabled}

      not alive_pid?(setting(context, :action_ledger)) ->
        {:error, :staged_plan_execution_not_enabled}

      true ->
        :ok
    end
  end

  defp task_supervisor(context, opts) do
    supervisor = Keyword.get(opts, :task_supervisor, setting(context, :task_supervisor))
    if alive_pid?(supervisor), do: {:ok, supervisor}, else: {:error, :task_supervisor_unavailable}
  end

  defp still_owned?(%{status: "running", runner_id: runner_id}, runner_id), do: :ok
  defp still_owned?(plan, _runner_id), do: {:error, {:staged_plan_run_interrupted, plan.status}}

  defp public_result(plan) do
    Map.take(plan, [
      :id,
      :status,
      :current_stage,
      :stage_results,
      :started_at,
      :completed_at,
      :final_result,
      :expires_at,
      :waiting_since,
      :next_evaluation_at,
      :waiting_kind,
      :observation_wakeup_count,
      :cancellation_requested_at,
      :cancellation_requested_by,
      :cancellation_request_reason,
      :cancelled_at,
      :cancelled_by,
      :cancellation_reason
    ])
  end

  defp normalize_result({:ok, value}), do: %{status: "ok", result: value}
  defp normalize_result({:error, reason}), do: %{status: "error", reason: inspect(reason)}
  defp normalize_result(value), do: %{status: "invalid", result: inspect(value)}

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp setting(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp alive_pid?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive_pid?(_value), do: false
end

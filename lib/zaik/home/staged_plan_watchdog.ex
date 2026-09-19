defmodule Zaik.Home.StagedPlanWatchdog do
  @moduledoc """
  Deterministic read-only diagnostics for durable staged-plan coordination.

  The watchdog never schedules, retries, cancels, or executes a plan. It reports
  missed wakeups, evaluations that have remained running beyond a threshold,
  and repeated failed scheduler outcomes from the bounded run journal.
  """

  @default_running_timeout_seconds 60
  @default_missed_wakeup_grace_seconds 5
  @default_consecutive_failure_threshold 3
  @failure_events ~w(failed timed_out task_exit)
  @outcome_events ~w(waiting completed cancelled failed timed_out task_exit)

  def evaluate(context, opts \\ []) when is_map(context) do
    store = setting(context, :staged_plan_store)
    clock = setting(context, :clock)
    now = Zaik.Time.now(clock)

    config = %{
      running_timeout_seconds:
        Keyword.get(opts, :running_timeout_seconds, @default_running_timeout_seconds),
      missed_wakeup_grace_seconds:
        Keyword.get(
          opts,
          :missed_wakeup_grace_seconds,
          @default_missed_wakeup_grace_seconds
        ),
      consecutive_failure_threshold:
        Keyword.get(
          opts,
          :consecutive_failure_threshold,
          @default_consecutive_failure_threshold
        )
    }

    with :ok <- validate_config(config),
         true <- process_available?(store) do
      issues =
        Zaik.Home.StagedPlanStore.active([clock: clock], store)
        |> Enum.flat_map(&plan_issues(&1, store, now, config))
        |> Enum.sort_by(&{severity_rank(&1.severity), &1.type, &1.plan_id})

      {:ok,
       %{
         status: if(issues == [], do: "healthy", else: "attention_required"),
         evaluated_at: DateTime.to_iso8601(now),
         issue_count: length(issues),
         issues: issues,
         thresholds: config
       }}
    else
      false -> {:error, :staged_plan_store_unavailable}
      error -> error
    end
  catch
    :exit, reason -> {:error, {:staged_plan_watchdog_unavailable, reason}}
  end

  defp plan_issues(plan, store, now, config) do
    events = Zaik.Home.StagedPlanStore.run_events(plan.id, 200, store)

    []
    |> maybe_add(missed_wakeup(plan, now, config))
    |> maybe_add(stuck_evaluation(plan, events, now, config))
    |> maybe_add(repeated_failures(plan, events, config))
  end

  defp missed_wakeup(%{status: "waiting", next_evaluation_at: value} = plan, now, config)
       when is_binary(value) do
    with {:ok, next_at, _offset} <- DateTime.from_iso8601(value),
         overdue_seconds when overdue_seconds > config.missed_wakeup_grace_seconds <-
           DateTime.diff(now, next_at, :second) do
      issue("missed_wakeup", "warning", plan, %{
        next_evaluation_at: value,
        overdue_seconds: overdue_seconds
      })
    else
      _ -> nil
    end
  end

  defp missed_wakeup(_plan, _now, _config), do: nil

  defp stuck_evaluation(%{status: "running"} = plan, events, now, config) do
    started_at =
      Enum.find_value(events, plan.started_at, fn event ->
        if event.event_type == "evaluation_started", do: event.recorded_at
      end)

    with started_at when is_binary(started_at) <- started_at,
         {:ok, started, _offset} <- DateTime.from_iso8601(started_at),
         age when age >= config.running_timeout_seconds <- DateTime.diff(now, started, :second) do
      issue("evaluation_stuck", "critical", plan, %{
        evaluation_started_at: started_at,
        age_seconds: age
      })
    else
      _ -> nil
    end
  end

  defp stuck_evaluation(_plan, _events, _now, _config), do: nil

  defp repeated_failures(plan, events, config) do
    failures =
      events
      |> Enum.filter(&(&1.event_type in @outcome_events))
      |> Enum.take_while(&(&1.event_type in @failure_events))

    if length(failures) >= config.consecutive_failure_threshold do
      issue("repeated_run_failure", "critical", plan, %{
        consecutive_failures: length(failures),
        latest_event: hd(failures).event_type,
        latest_failure_at: hd(failures).recorded_at
      })
    end
  end

  defp issue(type, severity, plan, evidence) do
    %{
      type: type,
      severity: severity,
      plan_id: plan.id,
      status: plan.status,
      current_stage: plan.current_stage,
      evidence: evidence
    }
  end

  defp maybe_add(issues, nil), do: issues
  defp maybe_add(issues, issue), do: [issue | issues]

  defp validate_config(config) do
    if Enum.all?(Map.values(config), &(is_integer(&1) and &1 >= 0)),
      do: :ok,
      else: {:error, :invalid_staged_plan_watchdog_config}
  end

  defp severity_rank("critical"), do: 0
  defp severity_rank("warning"), do: 1
  defp severity_rank(_severity), do: 2

  defp process_available?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp process_available?(name) when is_atom(name), do: not is_nil(Process.whereis(name))
  defp process_available?(_value), do: false

  defp setting(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

defmodule Zaik.Home.Autonomy.Watchdog do
  @moduledoc """
  Read-only diagnostics for repeated autonomy failures and degraded inputs.

  It inspects durable decisions plus the supervised required-write monitor. It
  cannot schedule evaluations, mutate desired state, retry, cancel, or execute.
  """

  @stale_reasons ~w(observation_stale observation_time_missing capability_state_missing)
  @oscillation_reasons ~w(policy_cooldown conflicting_action_pending)

  def evaluate(context \\ %{}, opts \\ []) when is_map(context) and is_list(opts) do
    decision_store = setting(context, :decision_store) || Zaik.Home.Autonomy.DecisionStore
    telemetry_monitor = setting(context, :telemetry_write_monitor) || Zaik.TelemetryWriteMonitor
    clock = setting(context, :clock)
    now = Zaik.Time.now(clock)

    config = %{
      decision_limit: Keyword.get(opts, :decision_limit, 100),
      window_seconds: Keyword.get(opts, :window_seconds, 15 * 60),
      stale_threshold: Keyword.get(opts, :stale_threshold, 2),
      oscillation_threshold: Keyword.get(opts, :oscillation_threshold, 3),
      non_convergence_threshold: Keyword.get(opts, :non_convergence_threshold, 2)
    }

    with :ok <- validate_config(config),
         decisions <-
           Zaik.Home.Autonomy.DecisionStore.recent(config.decision_limit, decision_store),
         recent <- Enum.filter(decisions, &recent?(&1, now, config.window_seconds)),
         telemetry <- Zaik.TelemetryWriteMonitor.status(telemetry_monitor) do
      issues =
        (decision_issues(recent, config) ++ telemetry_issues(telemetry))
        |> Enum.sort_by(&{severity_rank(&1.severity), &1.type, &1.scope})

      {:ok,
       %{
         status: if(issues == [], do: "healthy", else: "attention_required"),
         evaluated_at: DateTime.to_iso8601(now),
         issue_count: length(issues),
         issues: issues,
         thresholds: config
       }}
    end
  catch
    :exit, reason -> {:error, {:autonomy_watchdog_unavailable, exit_reason(reason)}}
  end

  defp decision_issues(decisions, config) do
    blocked =
      Enum.flat_map(decisions, fn decision ->
        decision
        |> value(:reconciliation)
        |> value(:blocked)
        |> List.wrap()
        |> Enum.map(fn entry ->
          %{
            reason: to_string(value(entry, :reason) || "unknown"),
            scope: decision_scope(decision, entry),
            decision_id: value(decision, :id),
            recorded_at: value(decision, :created_at)
          }
        end)
      end)

    stale =
      grouped_issues(
        blocked,
        @stale_reasons,
        config.stale_threshold,
        "stale_critical_input",
        "critical"
      )

    oscillation =
      grouped_issues(
        blocked,
        @oscillation_reasons,
        config.oscillation_threshold,
        "oscillation_prevented",
        "warning"
      )

    non_convergence =
      decisions
      |> Enum.flat_map(fn decision ->
        decision
        |> value(:outcomes)
        |> List.wrap()
        |> Enum.filter(&(to_string(value(&1, :status)) == "non_converged"))
        |> Enum.map(fn outcome ->
          %{
            scope: to_string(value(decision, :query) || "home"),
            decision_id: value(decision, :id),
            action_id: value(outcome, :action_id),
            recorded_at: value(outcome, :recorded_at) || value(decision, :created_at)
          }
        end)
      end)
      |> Enum.group_by(& &1.scope)
      |> Enum.flat_map(fn {scope, entries} ->
        if length(entries) >= config.non_convergence_threshold do
          [issue("repeated_non_convergence", "critical", scope, entries)]
        else
          []
        end
      end)

    stale ++ oscillation ++ non_convergence
  end

  defp grouped_issues(entries, reasons, threshold, type, severity) do
    entries
    |> Enum.filter(&(&1.reason in reasons))
    |> Enum.group_by(& &1.scope)
    |> Enum.flat_map(fn {scope, matches} ->
      if length(matches) >= threshold, do: [issue(type, severity, scope, matches)], else: []
    end)
  end

  defp issue(type, severity, scope, entries) do
    latest = Enum.max_by(entries, &to_string(&1.recorded_at), fn -> %{} end)

    %{
      type: type,
      severity: severity,
      scope: scope,
      evidence: %{
        occurrences: length(entries),
        latest_decision_id: Map.get(latest, :decision_id),
        latest_at: Map.get(latest, :recorded_at),
        reasons:
          entries |> Enum.map(&Map.get(&1, :reason)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      }
    }
  end

  defp telemetry_issues(%{status: :unavailable}) do
    [
      %{
        type: "required_telemetry_write_failure",
        severity: "critical",
        scope: "telemetry_write_monitor",
        evidence: %{failures: 1, latest_at: nil}
      }
    ]
  end

  defp telemetry_issues(%{unresolved: unresolved}) do
    Enum.map(unresolved, fn entry ->
      %{
        type: "required_telemetry_write_failure",
        severity: "critical",
        scope: to_string(Map.get(entry, :category, "telemetry")),
        evidence: %{
          failures: Map.get(entry, :failures, 0),
          latest_at: Map.get(entry, :last_failure_at)
        }
      }
    end)
  end

  defp telemetry_issues(_status), do: []

  defp decision_scope(decision, entry) do
    desired = value(entry, :desired) || %{}
    to_string(value(desired, :scope) || value(decision, :query) || "home")
  end

  defp recent?(decision, now, window_seconds) do
    case DateTime.from_iso8601(to_string(value(decision, :created_at))) do
      {:ok, created_at, _offset} -> DateTime.diff(now, created_at, :second) in 0..window_seconds
      _ -> false
    end
  end

  defp validate_config(config) do
    if Enum.all?(Map.values(config), &(is_integer(&1) and &1 >= 1)),
      do: :ok,
      else: {:error, :invalid_autonomy_watchdog_config}
  end

  defp severity_rank("critical"), do: 0
  defp severity_rank("warning"), do: 1
  defp severity_rank(_), do: 2

  defp exit_reason({:noproc, _}), do: :unavailable
  defp exit_reason({:timeout, _}), do: :timeout
  defp exit_reason(_), do: :exit
  defp setting(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

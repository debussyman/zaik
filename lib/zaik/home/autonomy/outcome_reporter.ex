defmodule Zaik.Home.Autonomy.OutcomeReporter do
  @moduledoc """
  Validates and durably correlates action lifecycle outcomes with autonomy decisions.

  Correlation metadata is inert provenance. It cannot authorize execution. When
  an action claims autonomy provenance, the decision, observation snapshot,
  candidate goal, and policy must all match the durable decision before the
  action ledger may accept the claim.
  """

  @statuses ~w(accepted verified failed cancelled timed_out non_converged)
  @required ~w(decision_id goal_id policy_id snapshot_id)a

  def causality(context) when is_map(context) do
    decision_id = value(context, :autonomy_decision_id)

    if blank?(decision_id) do
      %{}
    else
      %{
        decision_id: normalize(decision_id),
        goal_id: normalize(value(context, :autonomy_goal_id)),
        policy_id: normalize(value(context, :autonomy_policy_id)),
        snapshot_id: normalize(value(context, :autonomy_snapshot_id))
      }
    end
  end

  def validate_causality(causality, opts \\ []) when is_map(causality) do
    if map_size(causality) == 0 do
      :ok
    else
      with :ok <- require_fields(causality),
           {:ok, decision} <- lookup(value(causality, :decision_id), opts),
           :ok <- match_snapshot(causality, decision),
           :ok <- match_candidate(causality, decision) do
        :ok
      end
    end
  end

  def record(causality, status, attrs \\ %{}, opts \\ [])
      when is_map(causality) and is_map(attrs) do
    status = to_string(status)

    result =
      cond do
        map_size(causality) == 0 ->
          :ignored

        status not in @statuses ->
          {:error, {:invalid_autonomy_outcome_status, status}}

        true ->
          with :ok <- validate_causality(causality, opts),
               outcome <- outcome(causality, status, attrs),
               {:ok, _decision} <-
                 Zaik.Home.Autonomy.DecisionStore.record_outcome(
                   outcome["decision_id"],
                   outcome,
                   Keyword.get(opts, :decision_store, Zaik.Home.Autonomy.DecisionStore)
                 ) do
            :ok
          end
      end

    report_health(causality, status, result, opts)
    result
  catch
    :exit, reason ->
      result = {:error, {:autonomy_outcome_store_exit, exit_reason(reason)}}
      report_health(causality, status, result, opts)
      result
  end

  defp require_fields(causality) do
    case Enum.find(@required, &blank?(value(causality, &1))) do
      nil -> :ok
      field -> {:error, {:incomplete_autonomy_causality, field}}
    end
  end

  defp lookup(decision_id, opts) do
    Zaik.Home.Autonomy.DecisionStore.lookup(
      decision_id,
      Keyword.get(opts, :decision_store, Zaik.Home.Autonomy.DecisionStore)
    )
  catch
    :exit, reason -> {:error, {:decision_store_exit, exit_reason(reason)}}
  end

  defp match_snapshot(causality, decision) do
    if normalize(value(causality, :snapshot_id)) == normalize(value(decision, :snapshot_id)),
      do: :ok,
      else: {:error, :autonomy_snapshot_mismatch}
  end

  defp match_candidate(causality, decision) do
    goal_id = normalize(value(causality, :goal_id))
    policy_id = normalize(value(causality, :policy_id))

    match =
      decision
      |> value(:candidates)
      |> List.wrap()
      |> Enum.any?(fn candidate ->
        normalize(value(candidate, :id)) == goal_id and
          normalize(value(candidate, :policy_id)) == policy_id
      end)

    if match, do: :ok, else: {:error, :autonomy_goal_policy_mismatch}
  end

  defp outcome(causality, status, attrs) do
    base = %{
      "event_id" => event_id(causality, status, attrs),
      "type" => "action_execution",
      "status" => status,
      "decision_id" => normalize(value(causality, :decision_id)),
      "goal_id" => normalize(value(causality, :goal_id)),
      "policy_id" => normalize(value(causality, :policy_id)),
      "snapshot_id" => normalize(value(causality, :snapshot_id))
    }

    attrs
    |> Map.take([
      :action_id,
      "action_id",
      :ledger_key,
      "ledger_key",
      :tool,
      "tool",
      :verification_reason,
      "verification_reason",
      :observed_at,
      "observed_at"
    ])
    |> Map.new(fn {key, nested} -> {to_string(key), json_scalar(nested)} end)
    |> Map.merge(base)
  end

  defp event_id(causality, status, attrs) do
    stable = {
      normalize(value(causality, :decision_id)),
      normalize(value(causality, :goal_id)),
      status,
      normalize(value(attrs, :ledger_key)),
      normalize(value(attrs, :action_id)),
      normalize(value(attrs, :tool))
    }

    stable
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("outcome_" <> String.slice(&1, 0, 24)))
  end

  defp report_health(causality, status, result, opts) do
    if map_size(causality) > 0 and result != :ignored do
      Zaik.TelemetryWriteMonitor.report(
        :autonomy_outcome,
        result,
        %{
          decision_id: normalize(value(causality, :decision_id)),
          outcome_status: status
        },
        Keyword.get(opts, :telemetry_write_monitor, Zaik.TelemetryWriteMonitor)
      )
    end
  end

  defp json_scalar(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp json_scalar(nil), do: nil
  defp json_scalar(value), do: inspect(value, limit: 20, printable_limit: 200)

  defp blank?(value), do: not is_binary(normalize(value)) or normalize(value) == ""
  defp normalize(nil), do: nil
  defp normalize(value), do: value |> to_string() |> String.trim()
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp exit_reason({:noproc, _}), do: :unavailable
  defp exit_reason({:timeout, _}), do: :timeout
  defp exit_reason(_), do: :exit
end

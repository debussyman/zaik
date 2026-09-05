defmodule Zaik.Home.Tools.RetryAction do
  @moduledoc """
  Policy-gated retry of a previously accepted but unverified home action.

  The caller supplies only the original correlation ID. Original semantic
  targets come from the persistent ledger and are narrowed to unresolved plan
  actions. The deterministic retry policy must approve before execution.
  """

  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "retry_home_action",
      aliases: ["retry_action"],
      description:
        "Retry an expired unverified low-risk home action only when fresh state and policy allow it.",
      kind: :action,
      risk: :low,
      input_schema: %{
        "type" => "object",
        "required" => ["action_id"],
        "properties" => %{
          "action_id" => %{"type" => "string"}
        }
      }
    }
  end

  @impl true
  def run(args, context) do
    action_id = value(args, :action_id)
    ledger = setting(context, :action_ledger, Zaik.Home.ActionLedger)
    policy_opts = setting(context, :retry_policy_opts, [])

    with {:ok, action_id} <- non_empty(action_id),
         {:ok, entry} <- Zaik.Home.ActionLedger.lookup(action_id, ledger),
         {:ok, decision} <- Zaik.Home.ActionRetryPolicy.evaluate(entry, context, policy_opts),
         :ok <- reconcile_converged(entry, decision, ledger) do
      apply_decision(entry, decision, context)
    end
  catch
    :exit, reason -> {:error, {:retry_policy_unavailable, reason}}
  end

  defp apply_decision(
         _entry,
         %{eligible: false, reason: "already_converged"} = decision,
         _context
       ) do
    {:ok,
     %{
       retry_of: decision.action_id,
       retried: false,
       status: "verified",
       verified: true,
       policy_reason: decision.reason
     }}
  end

  defp apply_decision(_entry, %{eligible: false} = decision, _context),
    do: {:error, {:retry_not_eligible, decision}}

  defp apply_decision(entry, %{eligible: true} = decision, context) do
    registry_opts = setting(context, :registry_opts, [])

    case Zaik.Tools.Registry.run(
           decision.original_tool,
           decision.retry_args,
           Map.put(context, :retry_of, entry.idempotency_key),
           registry_opts
         ) do
      {:ok, result} ->
        {:ok,
         %{
           retry_of: entry.idempotency_key,
           retried: true,
           retry_attempt: decision.attempts_used + 1,
           status: value(result, :status) || "accepted",
           verified: value(result, :verified) == true,
           policy_reason: decision.reason,
           result: result
         }}

      {:error, reason} ->
        {:error, {:retry_execution_failed, entry.idempotency_key, reason}}

      other ->
        {:error, {:retry_execution_failed, entry.idempotency_key, other}}
    end
  end

  defp reconcile_converged(entry, decision, ledger) do
    decision.outcomes
    |> Enum.filter(fn outcome ->
      outcome.action_id in decision.reconciled_action_ids and
        outcome.disposition == :already_converged
    end)
    |> Enum.each(fn outcome ->
      Zaik.Home.ActionLedger.mark_verified(
        entry.idempotency_key,
        outcome.action_id,
        %{
          status: "verified",
          verified: true,
          observed_at: Map.get(outcome, :observed_at),
          observed: Map.get(outcome, :observed),
          reason: "current_state_converged_before_retry"
        },
        ledger
      )
    end)

    :ok
  end

  defp non_empty(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, :invalid_action_id}, else: {:ok, value}
  end

  defp non_empty(_value), do: {:error, :invalid_action_id}

  defp setting(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key), default)
    end
  end

  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

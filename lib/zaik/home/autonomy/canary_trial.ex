defmodule Zaik.Home.Autonomy.CanaryTrial do
  @moduledoc """
  Proposal/confirmation workflow for one operator-controlled low-risk action.

  This is not autonomous execution. A durable rollout eligibility approval must
  exist, proposal creation is inert, confirmation requires an exact proposal ID,
  current policy state is re-evaluated, and the action executes as explicit user
  authority through the normal ledger/verifier boundary. Continuous canary and
  active modes remain unavailable.
  """

  @schema_version 1

  def propose(rollout_id, selector, created_by, reason, opts \\ [])

  def propose(rollout_id, selector, created_by, reason, opts)
      when is_binary(rollout_id) and is_map(selector) and is_binary(reason) do
    rollout_store = Keyword.get(opts, :rollout_store, Zaik.Home.Autonomy.RolloutStore)

    with {:ok, created_by} <- non_empty(created_by, :missing_created_by),
         {:ok, rollout} <- Zaik.Home.Autonomy.RolloutStore.get(rollout_id, rollout_store),
         :ok <- active_rollout(rollout),
         {:ok, decision} <- evaluate(rollout.scope, opts),
         :ok <- decision_matches_rollout(decision, rollout),
         {:ok, action} <- select_action(decision, rollout, selector),
         :ok <- action_allowlisted(action, rollout),
         fingerprint <- action_fingerprint(rollout, action) do
      Zaik.Proposals.create(%{
        type: :home_canary_trial,
        title: "Operator-controlled #{rollout.policy_id} trial in #{rollout.scope}",
        body:
          "Confirming this proposal may perform exactly one low-risk physical action through normal verification. Continuous autonomy remains disabled.",
        action: %{
          kind: "execute_operator_canary_trial",
          schema_version: @schema_version,
          rollout_id: rollout.id,
          policy_id: rollout.policy_id,
          scope: rollout.scope,
          source_decision_id: decision.id,
          source_snapshot_id: decision.snapshot_id,
          action: action,
          action_fingerprint: fingerprint,
          reason: String.trim(reason)
        },
        metadata: %{
          rollout_id: rollout.id,
          policy_id: rollout.policy_id,
          scope: rollout.scope,
          action_fingerprint: fingerprint
        },
        created_by: created_by
      })
    end
  end

  def propose(_rollout_id, _selector, _created_by, _reason, _opts),
    do: {:error, :invalid_canary_trial_request}

  def confirm(proposal_id, approved_by, opts \\ [])

  def confirm(proposal_id, approved_by, opts) when is_binary(proposal_id) do
    with {:ok, approved_by} <- non_empty(approved_by, :missing_approved_by),
         {:ok, proposal} <- Zaik.Proposals.get(proposal_id),
         :ok <- proposal_type(proposal),
         {:ok, proposal} <- ensure_approved(proposal, approved_by),
         {:ok, trial} <- proposal_trial(proposal),
         {:ok, rollout} <- load_active_rollout(trial, opts),
         :ok <- action_fingerprint_matches(trial, rollout),
         {:ok, result} <- execute_or_replay(proposal, trial, rollout, approved_by, opts) do
      {:ok,
       %{
         proposal_id: proposal.id,
         rollout_id: rollout.id,
         approved_by: proposal.decided_by || approved_by,
         autonomy_execution_enabled: false,
         result: result
       }}
    end
  end

  def confirm(_proposal_id, _approved_by, _opts), do: {:error, :invalid_canary_proposal_id}

  defp execute_or_replay(proposal, trial, rollout, approved_by, opts) do
    args = action_args(trial.action)
    base_context = execution_context(proposal.id, rollout.id, trial, approved_by, opts)
    ledger = Keyword.get(opts, :action_ledger, Zaik.Home.ActionLedger)
    key = Zaik.Home.ActionLedger.idempotency_key("control_device", args, base_context)

    case Zaik.Home.ActionLedger.lookup(key, ledger) do
      {:ok, entry} ->
        context = Map.put(base_context, :operator_trial_causality, entry.causality)
        run_tool(args, context, opts)

      {:error, :not_found} ->
        with {:ok, decision} <- evaluate(rollout.scope, opts),
             :ok <- decision_matches_rollout(decision, rollout),
             {:ok, current_action} <- find_exact_action(decision, trial.action),
             :ok <- action_allowlisted(current_action, rollout),
             context <-
               Map.put(
                 base_context,
                 :operator_trial_causality,
                 trial_causality(decision, current_action, rollout)
               ),
             result <- run_tool(args, context, opts),
             :ok <-
               record_trial_outcome(decision, proposal, rollout, current_action, result, opts) do
          case result do
            {:ok, action_result} -> {:ok, action_result}
            {:error, reason} -> {:error, {:canary_action_failed, reason}}
            other -> {:error, {:invalid_canary_action_result, other}}
          end
        end

      {:error, :disabled} ->
        {:error, :canary_action_ledger_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_tool(args, context, opts) do
    case Keyword.get(opts, :tool_executor) do
      fun when is_function(fun, 3) ->
        fun.("control_device", args, context)

      _ ->
        Zaik.Tools.Executor.run(
          "control_device",
          args,
          context,
          Keyword.get(opts, :executor_opts, [])
        )
    end
  end

  defp record_trial_outcome(decision, proposal, rollout, action, result, opts) do
    status =
      case result do
        {:ok, nested} ->
          if value(nested, :verified) == true, do: "verified", else: "accepted"

        {:error, reason} ->
          if String.contains?(inspect(reason), "timeout"), do: "timed_out", else: "failed"

        _ ->
          "failed"
      end

    outcome = %{
      status: status,
      type: "operator_confirmed_canary_trial",
      proposal_id: proposal.id,
      rollout_id: rollout.id,
      action_id: result_action_id(result),
      goal_id: value(action, :candidate_id),
      policy_id: rollout.policy_id,
      snapshot_id: decision.snapshot_id
    }

    store = Keyword.get(opts, :decision_store, Zaik.Home.Autonomy.DecisionStore)
    monitor = Keyword.get(opts, :telemetry_write_monitor, Zaik.TelemetryWriteMonitor)
    write = Zaik.Home.Autonomy.DecisionStore.record_outcome(decision.id, outcome, store)

    result = if match?({:ok, _}, write), do: :ok, else: write

    Zaik.TelemetryWriteMonitor.report(
      :autonomy_outcome,
      result,
      %{decision_id: decision.id, outcome_status: status},
      monitor
    )

    result
  catch
    :exit, reason ->
      result = {:error, {:canary_outcome_store_exit, reason}}

      Zaik.TelemetryWriteMonitor.report(
        :autonomy_outcome,
        result,
        %{decision_id: decision.id, outcome_status: "unknown"},
        Keyword.get(opts, :telemetry_write_monitor, Zaik.TelemetryWriteMonitor)
      )

      result
  end

  defp load_active_rollout(trial, opts) do
    store = Keyword.get(opts, :rollout_store, Zaik.Home.Autonomy.RolloutStore)

    with {:ok, rollout} <- Zaik.Home.Autonomy.RolloutStore.get(trial.rollout_id, store),
         :ok <- active_rollout(rollout) do
      {:ok, rollout}
    end
  end

  defp evaluate(scope, opts) do
    case Keyword.get(opts, :evaluator) do
      fun when is_function(fun, 1) -> fun.(scope)
      _ -> Zaik.Home.Autonomy.Engine.evaluate(scope, Keyword.get(opts, :evaluation_opts, []))
    end
  end

  defp decision_matches_rollout(decision, rollout) do
    cond do
      to_string(value(decision, :query)) != rollout.scope ->
        {:error, :canary_scope_changed}

      to_string(value(decision, :policy_fingerprint)) !=
          rollout.report["policy_registry_fingerprint"] ->
        {:error, :canary_policy_registry_changed}

      true ->
        :ok
    end
  end

  defp select_action(decision, rollout, selector) do
    matches =
      decision
      |> value(:reconciliation)
      |> value(:actions)
      |> List.wrap()
      |> Enum.filter(fn action ->
        to_string(value(action, :policy_id)) == rollout.policy_id and
          selector_match?(action, selector)
      end)

    case matches do
      [action] -> {:ok, stringify(action)}
      [] -> {:error, :canary_action_not_currently_proposed}
      _ -> {:error, :canary_action_selector_ambiguous}
    end
  end

  defp find_exact_action(decision, expected) do
    actions = decision |> value(:reconciliation) |> value(:actions) |> List.wrap()

    case Enum.find(actions, &(semantic_action(&1) == semantic_action(expected))) do
      nil -> {:error, :canary_action_no_longer_proposed}
      action -> {:ok, stringify(action)}
    end
  end

  defp selector_match?(action, selector) do
    entity = value(selector, :entity_id) || value(selector, :device)
    capability = value(selector, :capability)

    entity_match =
      is_binary(entity) and
        (to_string(value(action, :entity_id)) == entity or
           to_string(value(action, :device)) == entity)

    capability_match =
      is_binary(capability) and to_string(value(action, :capability)) == capability

    entity_match and capability_match
  end

  defp action_allowlisted(action, rollout) do
    requirements = rollout.report["requirements"] || %{}
    capabilities = List.wrap(requirements["allowed_capabilities"])

    if to_string(value(action, :capability)) in capabilities,
      do: :ok,
      else: {:error, :canary_capability_not_allowlisted}
  end

  defp action_fingerprint_matches(trial, rollout) do
    if action_fingerprint(rollout, trial.action) == trial.action_fingerprint,
      do: :ok,
      else: {:error, :canary_action_fingerprint_mismatch}
  end

  defp action_fingerprint(rollout, action) do
    {rollout.id, rollout.report_id, canonical(action)}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp trial_causality(decision, action, rollout) do
    %{
      decision_id: decision.id,
      goal_id: to_string(value(action, :candidate_id)),
      policy_id: rollout.policy_id,
      snapshot_id: decision.snapshot_id
    }
  end

  defp semantic_action(action) do
    action
    |> stringify()
    |> Map.take(["entity_id", "device", "capability", "target", "policy_id"])
    |> canonical()
  end

  defp action_args(action) do
    %{
      "device" => to_string(value(action, :device)),
      "capability" => to_string(value(action, :capability)),
      "target" => stringify(value(action, :target))
    }
  end

  defp execution_context(proposal_id, rollout_id, trial, approved_by, opts) do
    %{
      channel: "operator_canary_trial",
      chat_id: actor_fingerprint(approved_by),
      message_id: proposal_id,
      sender_id: actor_fingerprint(approved_by),
      canary_rollout_id: rollout_id,
      source_autonomy_decision_id: trial.source_decision_id,
      source_snapshot_id: trial.source_snapshot_id,
      device_store: Keyword.get(opts, :device_store),
      history_store: Keyword.get(opts, :history_store),
      preset_store: Keyword.get(opts, :preset_store),
      mqtt_client: Keyword.get(opts, :mqtt_client),
      action_verifier: Keyword.get(opts, :action_verifier),
      action_ledger: Keyword.get(opts, :action_ledger)
    }
    |> Enum.reject(fn {_key, nested} -> is_nil(nested) end)
    |> Map.new()
  end

  defp result_action_id({:ok, result}), do: value(result, :action_id)
  defp result_action_id(_result), do: nil

  defp proposal_trial(proposal) do
    action = proposal.action || %{}

    with "execute_operator_canary_trial" <- value(action, :kind),
         @schema_version <- value(action, :schema_version),
         rollout_id when is_binary(rollout_id) <- value(action, :rollout_id),
         trial_action when is_map(trial_action) <- value(action, :action),
         fingerprint when is_binary(fingerprint) <- value(action, :action_fingerprint) do
      {:ok,
       %{
         rollout_id: rollout_id,
         policy_id: to_string(value(action, :policy_id)),
         scope: to_string(value(action, :scope)),
         source_decision_id: to_string(value(action, :source_decision_id)),
         source_snapshot_id: to_string(value(action, :source_snapshot_id)),
         action: stringify(trial_action),
         action_fingerprint: fingerprint
       }}
    else
      _ -> {:error, :invalid_canary_proposal_action}
    end
  end

  defp proposal_type(%{type: "home_canary_trial"}), do: :ok
  defp proposal_type(%{type: :home_canary_trial}), do: :ok
  defp proposal_type(_proposal), do: {:error, :not_a_canary_trial_proposal}

  defp ensure_approved(%{status: "pending"} = proposal, approved_by),
    do: Zaik.Proposals.approve(proposal.id, approved_by)

  defp ensure_approved(%{status: "approved", decided_by: decided_by} = proposal, approved_by)
       when is_binary(decided_by) and decided_by == approved_by,
       do: {:ok, proposal}

  defp ensure_approved(%{status: "approved"}, _approved_by),
    do: {:error, :canary_proposal_operator_mismatch}

  defp ensure_approved(%{status: "rejected"}, _approved_by),
    do: {:error, :canary_proposal_rejected}

  defp ensure_approved(_proposal, _approved_by), do: {:error, :invalid_canary_proposal_status}

  defp active_rollout(%{status: "approved", execution_enabled: false}), do: :ok
  defp active_rollout(_rollout), do: {:error, :canary_rollout_not_active}

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp canonical(value) when is_map(value),
    do:
      value
      |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
      |> Enum.sort()

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp actor_fingerprint(actor) do
    :crypto.hash(:sha256, actor)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp non_empty(value, error) do
    value = value |> to_string() |> String.trim()
    if value == "", do: {:error, error}, else: {:ok, value}
  end

  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

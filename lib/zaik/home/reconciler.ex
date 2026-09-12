defmodule Zaik.Home.Reconciler do
  @moduledoc """
  Pure desired-state reconciliation against a canonical room snapshot.

  The reconciler emits inert action arguments for unresolved fresh state. It
  never executes tools and blocks actions when the referenced entity or current
  capability observation is missing or stale.
  """

  def apply_action_budget(reconciliation, %{allowed: allowed, blocked: blocked})
      when is_map(reconciliation) and is_list(allowed) and is_list(blocked) do
    budget_blocks =
      Enum.map(blocked, fn entry ->
        %{
          action: value(entry, :action),
          reason: value(entry, :reason) || "action_budget_exceeded",
          dimensions: value(entry, :dimensions)
        }
      end)

    reconciliation
    |> Map.put(:actions, allowed)
    |> Map.update(:blocked, budget_blocks, &(&1 ++ budget_blocks))
    |> Map.delete(:fingerprint)
    |> then(&Map.put(&1, :fingerprint, fingerprint(&1)))
  end

  def diff(%{selected: selected}, room_context, opts \\ []) when is_list(selected) do
    now = Zaik.Time.now(Keyword.get(opts, :clock))
    max_state_age_seconds = Keyword.get(opts, :max_state_age_seconds, 120)

    entities =
      room_context
      |> value(:entities)
      |> List.wrap()
      |> Map.new(&{to_string(value(&1, :id)), &1})

    result =
      Enum.reduce(selected, %{actions: [], satisfied: [], blocked: []}, fn desired, acc ->
        reconcile_one(desired, entities, room_context, now, max_state_age_seconds, opts, acc)
      end)

    result = %{
      evaluated_at: DateTime.to_iso8601(now),
      actions: Enum.reverse(result.actions),
      satisfied: Enum.reverse(result.satisfied),
      blocked: Enum.reverse(result.blocked)
    }

    Map.put(result, :fingerprint, fingerprint(result))
  end

  defp reconcile_one(desired, entities, room_context, now, max_age, opts, acc) do
    entity_id = to_string(value(desired, :entity_id))

    case Map.get(entities, entity_id) do
      nil ->
        block(acc, desired, "entity_not_found")

      entity ->
        capability = to_string(value(desired, :capability))
        capability_state = entity |> value(:state) |> capability_state(capability)
        observed_at = parse_datetime(value(entity, :observed_at))

        cond do
          not is_map(capability_state) ->
            block(acc, desired, "capability_state_missing")

          is_nil(observed_at) ->
            block(acc, desired, "observation_time_missing")

          DateTime.diff(now, observed_at, :second) > max_age ->
            block(acc, desired, "observation_stale")

          Zaik.Home.ActionVerifier.converged?(
            capability,
            value(desired, :target),
            capability_state,
            Keyword.get(opts, :verification_opts, [])
          ) ->
            %{acc | satisfied: [desired | acc.satisfied]}

          true ->
            case stability_block(desired, room_context, now, opts) do
              nil ->
                action = %{
                  entity_id: entity_id,
                  device: value(desired, :device),
                  capability: capability,
                  target: value(desired, :target),
                  candidate_id: value(desired, :candidate_id),
                  policy_id: value(desired, :policy_id)
                }

                %{acc | actions: [action | acc.actions]}

              block ->
                block(acc, desired, block.reason, Map.delete(block, :reason))
            end
        end
    end
  end

  defp stability_block(desired, context, now, opts) do
    stability =
      opts
      |> Keyword.get(:policy_stability, %{})
      |> Map.get(to_string(value(desired, :policy_id)), %{})

    settle_seconds = non_negative(value(stability, :settle_seconds))
    cooldown_seconds = non_negative(value(stability, :cooldown_seconds))

    active =
      Enum.find(List.wrap(value(context, :desired_state_leases)), &same_desired?(&1, desired))

    cond do
      active && settle_seconds > 0 ->
        remaining = settle_seconds - elapsed_seconds(value(active, :created_at), now)

        if remaining > 0,
          do: %{reason: "policy_settling", retry_after_seconds: remaining},
          else: nil

      is_nil(active) ->
        cooldown_block(desired, context, now, cooldown_seconds) ||
          if(settle_seconds > 0,
            do: %{reason: "policy_settling", retry_after_seconds: settle_seconds}
          )

      true ->
        nil
    end
  end

  defp cooldown_block(desired, context, now, cooldown_seconds) do
    previous =
      context
      |> value(:desired_state_history)
      |> List.wrap()
      |> Enum.filter(&same_desired?(&1, desired))
      |> Enum.map(fn lease -> {lease, ended_at(lease, now)} end)
      |> Enum.reject(fn {_lease, ended_at} ->
        is_nil(ended_at) or DateTime.after?(ended_at, now)
      end)
      |> Enum.max_by(fn {_lease, ended_at} -> DateTime.to_unix(ended_at, :microsecond) end, fn ->
        nil
      end)

    case previous do
      nil ->
        nil

      {_lease, ended_at} ->
        remaining = cooldown_seconds - DateTime.diff(now, ended_at, :second)

        if remaining > 0,
          do: %{reason: "policy_cooldown", retry_after_seconds: remaining},
          else: nil
    end
  end

  defp ended_at(lease, now) do
    case value(lease, :status) do
      "superseded" ->
        parse_datetime(value(lease, :superseded_at))

      _ ->
        expires_at = parse_datetime(value(lease, :expires_at))
        if expires_at && not DateTime.after?(expires_at, now), do: expires_at
    end
  end

  defp same_desired?(lease, desired) do
    value(lease, :source_id) == value(desired, :policy_id) and
      to_string(value(lease, :entity_id)) == to_string(value(desired, :entity_id)) and
      to_string(value(lease, :capability)) == to_string(value(desired, :capability)) and
      value(lease, :target) == value(desired, :target)
  end

  defp elapsed_seconds(value, now) do
    case parse_datetime(value) do
      nil -> 0
      datetime -> max(0, DateTime.diff(now, datetime, :second))
    end
  end

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: 0

  defp block(acc, desired, reason, details \\ %{}),
    do: %{acc | blocked: [Map.merge(%{desired: desired, reason: reason}, details) | acc.blocked]}

  defp capability_state(nil, _capability), do: nil

  defp capability_state(state, capability) when is_map(state),
    do: Map.get(state, capability) || Map.get(state, String.to_atom(capability))

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp fingerprint(result) do
    result
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp value(nil, _key), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
end

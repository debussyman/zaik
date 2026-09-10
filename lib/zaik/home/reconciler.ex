defmodule Zaik.Home.Reconciler do
  @moduledoc """
  Pure desired-state reconciliation against a canonical room snapshot.

  The reconciler emits inert action arguments for unresolved fresh state. It
  never executes tools and blocks actions when the referenced entity or current
  capability observation is missing or stale.
  """

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
        reconcile_one(desired, entities, now, max_state_age_seconds, opts, acc)
      end)

    result = %{
      evaluated_at: DateTime.to_iso8601(now),
      actions: Enum.reverse(result.actions),
      satisfied: Enum.reverse(result.satisfied),
      blocked: Enum.reverse(result.blocked)
    }

    Map.put(result, :fingerprint, fingerprint(result))
  end

  defp reconcile_one(desired, entities, now, max_age, opts, acc) do
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
            action = %{
              device: value(desired, :device),
              capability: capability,
              target: value(desired, :target),
              candidate_id: value(desired, :candidate_id),
              policy_id: value(desired, :policy_id)
            }

            %{acc | actions: [action | acc.actions]}
        end
    end
  end

  defp block(acc, desired, reason),
    do: %{acc | blocked: [%{desired: desired, reason: reason} | acc.blocked]}

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

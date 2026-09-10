defmodule Zaik.Home.Arbitrator do
  @moduledoc """
  Deterministically selects one desired target per entity capability.

  Arbitration is pure and inert. It records expired, duplicate, and conflicting
  candidates but never executes the selected targets.
  """

  def arbitrate(candidates, opts \\ []) when is_list(candidates) do
    now = Zaik.Time.now(Keyword.get(opts, :clock))
    {active, expired} = Enum.split_with(candidates, &active?(&1, now))

    {selected, suppressed} =
      active
      |> desired_entries()
      |> Enum.group_by(& &1.key)
      |> Enum.sort_by(fn {key, _entries} -> key end)
      |> Enum.reduce({[], expired_suppressions(expired)}, fn {_key, entries},
                                                             {chosen, rejected} ->
        sorted = Enum.sort_by(entries, &rank/1)
        winner = hd(sorted)

        suppressions =
          sorted
          |> tl()
          |> Enum.map(fn entry ->
            %{
              candidate_id: entry.candidate.id,
              entity_id: entry.action.entity_id,
              capability: entry.action.capability,
              target: entry.action.target,
              reason: suppression_reason(winner, entry),
              selected_candidate_id: winner.candidate.id
            }
          end)

        {[selected_entry(winner) | chosen], rejected ++ suppressions}
      end)

    result = %{
      evaluated_at: DateTime.to_iso8601(now),
      selected: Enum.sort_by(selected, &{&1.entity_id, &1.capability}),
      suppressed: Enum.sort_by(suppressed, &suppression_sort_key/1)
    }

    Map.put(result, :fingerprint, fingerprint(result))
  end

  defp desired_entries(candidates) do
    Enum.flat_map(candidates, fn candidate ->
      Enum.map(candidate.desired_state, fn action ->
        %{key: {action.entity_id, action.capability}, action: action, candidate: candidate}
      end)
    end)
  end

  # Descending priority, then deterministic policy/candidate identity.
  defp rank(entry) do
    {-entry.candidate.priority, entry.candidate.policy_id, entry.candidate.id,
     inspect(entry.action.target)}
  end

  defp selected_entry(entry) do
    Map.merge(entry.action, %{
      candidate_id: entry.candidate.id,
      policy_id: entry.candidate.policy_id,
      policy_version: entry.candidate.policy_version,
      priority: entry.candidate.priority,
      evidence: entry.candidate.evidence,
      reason: entry.candidate.reason,
      expires_at: entry.candidate.expires_at
    })
  end

  defp suppression_reason(winner, entry) do
    if winner.action.target == entry.action.target do
      "equivalent_lower_priority"
    else
      "conflicting_lower_priority"
    end
  end

  defp active?(candidate, now) do
    case DateTime.from_iso8601(candidate.expires_at) do
      {:ok, expires_at, _offset} -> DateTime.after?(expires_at, now)
      _ -> false
    end
  end

  defp expired_suppressions(candidates) do
    Enum.flat_map(candidates, fn candidate ->
      Enum.map(candidate.desired_state, fn action ->
        %{
          candidate_id: candidate.id,
          entity_id: action.entity_id,
          capability: action.capability,
          target: action.target,
          reason: "expired",
          selected_candidate_id: nil
        }
      end)
    end)
  end

  defp suppression_sort_key(entry),
    do: {entry.entity_id, entry.capability, entry.reason, entry.candidate_id}

  defp fingerprint(result) do
    result
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

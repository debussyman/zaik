defmodule Zaik.Home.Autonomy.ConflictLock do
  @moduledoc """
  Pure pre-execution lock assessment against in-flight physical actions.

  A pending equivalent target suppresses duplicate publication. A pending
  different target blocks contradictory movement until the verifier reaches a
  terminal state. The lock never executes or mutates an action.
  """

  def assess(actions, pending, opts \\ []) when is_list(actions) and is_list(pending) do
    now = Zaik.Time.now(Keyword.get(opts, :clock))

    {allowed, blocked} =
      Enum.reduce(actions, {[], []}, fn action, {allowed, blocked} ->
        case lock_for(action, pending) do
          nil ->
            {[action | allowed], blocked}

          lock ->
            reason =
              if value(lock, :target) == value(action, :target),
                do: "equivalent_action_pending",
                else: "conflicting_action_pending"

            entry = %{
              action: action,
              reason: reason,
              pending_action_id: value(lock, :action_id),
              pending_target: value(lock, :target),
              retry_after_seconds: retry_after(lock, now)
            }

            {allowed, [entry | blocked]}
        end
      end)

    %{
      status: if(blocked == [], do: "clear", else: "blocked"),
      allowed: Enum.reverse(allowed),
      blocked: Enum.reverse(blocked),
      assessed_at: DateTime.to_iso8601(now)
    }
  end

  defp lock_for(action, pending) do
    action_device = normalize(value(action, :device))
    capability = normalize(value(action, :capability))

    Enum.find(pending, fn lock ->
      normalize(value(lock, :device)) == action_device and
        normalize(value(lock, :capability)) == capability and
        value(lock, :status) in ["registered", "pending"]
    end)
  end

  defp retry_after(lock, now) do
    case parse_time(value(lock, :expires_at)) do
      nil -> 1
      expires_at -> max(1, DateTime.diff(expires_at, now, :second))
    end
  end

  defp parse_time(%DateTime{} = value), do: value

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_time(_value), do: nil
  defp normalize(nil), do: ""
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp value(nil, _key), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
end

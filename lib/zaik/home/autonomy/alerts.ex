defmodule Zaik.Home.Autonomy.Alerts do
  @moduledoc """
  Explicit cooldown-protected operator delivery for autonomy watchdog issues.

  This module only reads diagnostics and records notification delivery. It has no
  policy evaluation, scheduling, retry, cancellation, or execution authority.
  """

  @default_cooldown_seconds 15 * 60

  def deliver(context \\ %{}, opts \\ []) when is_map(context) and is_list(opts) do
    chat_id = normalize_chat_id(Keyword.get(opts, :chat_id))
    notifier = Keyword.get(opts, :notifier, Zaik.Messaging.TelegramClient)
    cooldown_seconds = Keyword.get(opts, :cooldown_seconds, @default_cooldown_seconds)
    decision_store = setting(context, :decision_store) || Zaik.Home.Autonomy.DecisionStore
    clock = setting(context, :clock)

    with {:ok, chat_id} <- chat_id,
         :ok <- validate_cooldown(cooldown_seconds),
         {:ok, diagnostics} <-
           Zaik.Home.Autonomy.Watchdog.evaluate(
             context,
             Keyword.get(opts, :watchdog_opts, [])
           ) do
      summary =
        Enum.reduce(
          diagnostics.issues,
          %{sent: 0, suppressed: 0, errors: 0, notifications: []},
          fn issue, summary ->
            deliver_issue(
              issue,
              chat_id,
              notifier,
              decision_store,
              clock,
              cooldown_seconds,
              summary
            )
          end
        )

      {:ok, Map.put(summary, :diagnostics, diagnostics)}
    end
  end

  defp deliver_issue(issue, chat_id, notifier, store, clock, cooldown, summary) do
    fingerprint = issue_fingerprint(issue)

    attrs = %{
      issue_type: issue.type,
      details: %{severity: issue.severity, scope: issue.scope, evidence: issue.evidence},
      destination_fingerprint: destination_fingerprint(chat_id)
    }

    case Zaik.Home.Autonomy.DecisionStore.claim_alert_delivery(
           fingerprint,
           attrs,
           [clock: clock, cooldown_seconds: cooldown],
           store
         ) do
      {:suppressed, _delivered_at} ->
        %{summary | suppressed: summary.suppressed + 1}

      {:ok, token} ->
        case notify(notifier, chat_id, notification_text(issue)) do
          {:ok, _result} ->
            case Zaik.Home.Autonomy.DecisionStore.complete_alert_delivery(
                   fingerprint,
                   token,
                   store
                 ) do
              :ok ->
                %{
                  summary
                  | sent: summary.sent + 1,
                    notifications: [
                      %{type: issue.type, scope: issue.scope, fingerprint: fingerprint}
                      | summary.notifications
                    ]
                }

              {:error, _reason} ->
                %{summary | errors: summary.errors + 1}
            end

          _error ->
            _ = Zaik.Home.Autonomy.DecisionStore.release_alert_delivery(fingerprint, token, store)
            %{summary | errors: summary.errors + 1}
        end

      {:error, _reason} ->
        %{summary | errors: summary.errors + 1}
    end
  catch
    :exit, _reason -> %{summary | errors: summary.errors + 1}
  end

  defp notification_text(issue) do
    evidence =
      issue.evidence
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{format(value)}" end)

    """
    Zaik autonomy alert: #{issue.type}
    Severity: #{issue.severity}
    Scope: #{issue.scope}
    Evidence: #{evidence}
    """
    |> String.trim()
  end

  defp issue_fingerprint(issue) do
    {issue.type, issue.severity, issue.scope}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  defp destination_fingerprint(chat_id) do
    :crypto.hash(:sha256, chat_id)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp notify(notifier, chat_id, text) when is_function(notifier, 2),
    do: notifier.(chat_id, text)

  defp notify(notifier, chat_id, text) when is_atom(notifier),
    do: notifier.send_message(chat_id, text)

  defp notify(_notifier, _chat_id, _text), do: {:error, :invalid_autonomy_alert_notifier}

  defp normalize_chat_id(nil), do: {:error, :autonomy_alert_chat_id_required}

  defp normalize_chat_id(value) do
    case value |> to_string() |> String.trim() do
      "" -> {:error, :autonomy_alert_chat_id_required}
      chat_id -> {:ok, chat_id}
    end
  end

  defp validate_cooldown(value) when is_integer(value) and value >= 1, do: :ok
  defp validate_cooldown(_value), do: {:error, :invalid_autonomy_alert_cooldown}

  defp format(value) when is_list(value), do: Enum.join(value, "|")
  defp format(value), do: to_string(value)
  defp setting(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

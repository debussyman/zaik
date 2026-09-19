defmodule Zaik.Home.StagedPlanAlerts do
  @moduledoc """
  Explicit, durable, cooldown-protected delivery of staged-plan watchdog issues.

  Delivery is operator-invoked and read-only with respect to plan execution.
  Successful notifications are journaled as `alert_emitted` run events so a
  process restart cannot bypass the cooldown.
  """

  @default_cooldown_seconds 15 * 60

  def deliver(context, opts \\ []) when is_map(context) and is_list(opts) do
    chat_id = opts |> Keyword.get(:chat_id) |> normalize_chat_id()
    notifier = Keyword.get(opts, :notifier, Zaik.Messaging.TelegramClient)
    cooldown_seconds = Keyword.get(opts, :cooldown_seconds, @default_cooldown_seconds)
    watchdog_opts = Keyword.get(opts, :watchdog_opts, [])

    with {:ok, chat_id} <- chat_id,
         :ok <- validate_cooldown(cooldown_seconds),
         {:ok, diagnostics} <- Zaik.Home.StagedPlanWatchdog.evaluate(context, watchdog_opts) do
      summary =
        Enum.reduce(
          diagnostics.issues,
          %{sent: 0, suppressed: 0, errors: 0, notifications: []},
          fn issue, summary ->
            deliver_issue(issue, chat_id, notifier, cooldown_seconds, context, summary)
          end
        )

      {:ok, Map.put(summary, :diagnostics, diagnostics)}
    end
  end

  defp deliver_issue(issue, chat_id, notifier, cooldown_seconds, context, summary) do
    fingerprint = issue_fingerprint(issue)

    if cooldown_active?(issue.plan_id, fingerprint, cooldown_seconds, context) do
      %{summary | suppressed: summary.suppressed + 1}
    else
      text = notification_text(issue)

      case notify(notifier, chat_id, text) do
        {:ok, _result} ->
          case record_delivery(issue, fingerprint, chat_id, context) do
            {:ok, _event} ->
              %{
                summary
                | sent: summary.sent + 1,
                  notifications: [
                    %{plan_id: issue.plan_id, type: issue.type, fingerprint: fingerprint}
                    | summary.notifications
                  ]
              }

            {:error, _reason} ->
              %{summary | errors: summary.errors + 1}
          end

        {:error, _reason} ->
          %{summary | errors: summary.errors + 1}

        _invalid ->
          %{summary | errors: summary.errors + 1}
      end
    end
  end

  defp cooldown_active?(plan_id, fingerprint, cooldown_seconds, context) do
    store = setting(context, :staged_plan_store)
    now = Zaik.Time.now(setting(context, :clock))

    Zaik.Home.StagedPlanStore.run_events_by_type(plan_id, :alert_emitted, 200, store)
    |> Enum.find(fn event ->
      event.event_type == "alert_emitted" and event.details["fingerprint"] == fingerprint
    end)
    |> case do
      nil ->
        false

      event ->
        case DateTime.from_iso8601(event.recorded_at) do
          {:ok, delivered_at, _offset} ->
            DateTime.diff(now, delivered_at, :second) < cooldown_seconds

          _ ->
            false
        end
    end
  end

  defp record_delivery(issue, fingerprint, chat_id, context) do
    Zaik.Home.StagedPlanStore.record_run_event(
      issue.plan_id,
      :alert_emitted,
      %{
        fingerprint: fingerprint,
        issue_type: issue.type,
        severity: issue.severity,
        chat_id_fingerprint: chat_id_fingerprint(chat_id)
      },
      [clock: setting(context, :clock)],
      setting(context, :staged_plan_store)
    )
  end

  defp notification_text(issue) do
    evidence =
      issue.evidence
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)

    """
    Zaik staged-plan alert: #{issue.type}
    Severity: #{issue.severity}
    Plan: #{issue.plan_id}
    Status: #{issue.status}
    Stage: #{issue.current_stage}
    Evidence: #{evidence}
    """
    |> String.trim()
  end

  defp issue_fingerprint(issue) do
    %{
      plan_id: issue.plan_id,
      type: issue.type,
      severity: issue.severity,
      current_stage: issue.current_stage
    }
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  defp chat_id_fingerprint(chat_id) do
    :crypto.hash(:sha256, chat_id)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp notify(notifier, chat_id, text) when is_function(notifier, 2),
    do: notifier.(chat_id, text)

  defp notify(notifier, chat_id, text) when is_atom(notifier),
    do: notifier.send_message(chat_id, text)

  defp notify(_notifier, _chat_id, _text), do: {:error, :invalid_staged_plan_notifier}

  defp normalize_chat_id(nil), do: {:error, :staged_plan_alert_chat_id_required}

  defp normalize_chat_id(value) do
    case value |> to_string() |> String.trim() do
      "" -> {:error, :staged_plan_alert_chat_id_required}
      chat_id -> {:ok, chat_id}
    end
  end

  defp validate_cooldown(value) when is_integer(value) and value >= 1, do: :ok
  defp validate_cooldown(_value), do: {:error, :invalid_staged_plan_alert_cooldown}

  defp setting(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

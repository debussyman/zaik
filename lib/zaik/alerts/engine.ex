defmodule Zaik.Alerts.Engine do
  @moduledoc """
  Evaluates home events against active alert rules.

  The MVP supports presence-detected alerts with per-rule cooldown so repeated
  sensor updates do not spam outgoing chat messages.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def evaluate_device_update(friendly_name, payload)
      when is_binary(friendly_name) and is_map(payload) do
    evaluate_device_update(__MODULE__, friendly_name, payload, %{}, [])
  end

  def evaluate_device_update(friendly_name, payload, metadata)
      when is_binary(friendly_name) and is_map(payload) and is_map(metadata) do
    evaluate_device_update(__MODULE__, friendly_name, payload, metadata, [])
  end

  def evaluate_device_update(server, friendly_name, payload, metadata)
      when is_binary(friendly_name) and is_map(payload) and is_map(metadata) do
    evaluate_device_update(server, friendly_name, payload, metadata, [])
  end

  def evaluate_device_update(server, friendly_name, payload, metadata, opts)
      when is_binary(friendly_name) and is_map(payload) and is_map(metadata) and is_list(opts) do
    GenServer.call(server, {:device_update, friendly_name, payload, metadata, opts})
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       rule_store: Keyword.get(opts, :rule_store, Zaik.Alerts.RuleStore),
       notifier: Keyword.get(opts, :notifier, Zaik.Messaging.TelegramClient)
     }}
  end

  @impl true
  def handle_call({:device_update, friendly_name, payload, metadata, opts}, _from, state) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    result =
      if presence_detected?(payload) do
        Zaik.Alerts.RuleStore.list(:active, state.rule_store)
        |> Enum.filter(&active_presence_rule?(&1, now))
        |> Enum.reduce(%{triggered: 0, suppressed: 0, errors: 0}, fn rule, summary ->
          evaluate_rule(rule, friendly_name, payload, metadata, now, state, summary)
        end)
      else
        %{triggered: 0, suppressed: 0, errors: 0}
      end

    {:reply, result, state}
  end

  defp evaluate_rule(rule, friendly_name, payload, metadata, now, state, summary) do
    cond do
      in_cooldown?(rule, now) ->
        %{summary | suppressed: summary.suppressed + 1}

      true ->
        text = notification_text(rule, friendly_name, payload, metadata, now)

        case notify(rule, text, state) do
          {:ok, _result} ->
            Zaik.Alerts.RuleStore.record_trigger(rule["id"], now, state.rule_store)
            %{summary | triggered: summary.triggered + 1}

          {:error, reason} ->
            Logger.warning("Alert notification failed: #{inspect(reason)}")
            %{summary | errors: summary.errors + 1}
        end
    end
  end

  defp notify(%{"notify_channel" => "telegram", "notify_chat_id" => chat_id}, text, state)
       when is_binary(chat_id) and chat_id != "" do
    state.notifier.send_message(chat_id, text)
  end

  defp notify(rule, _text, _state), do: {:error, {:unsupported_notifier, rule["notify_channel"]}}

  defp active_presence_rule?(rule, now) do
    rule["status"] == "active" and rule["type"] == "presence_detected" and
      within_window?(rule, now)
  end

  defp within_window?(rule, now) do
    with {:ok, starts_at} <- parse_datetime(rule["starts_at"]),
         {:ok, ends_at} <- parse_datetime(rule["ends_at"]) do
      DateTime.compare(now, starts_at) in [:eq, :gt] and
        DateTime.compare(now, ends_at) in [:eq, :lt]
    else
      _ -> false
    end
  end

  defp in_cooldown?(rule, now) do
    cooldown = rule["cooldown_seconds"] || 900

    case parse_datetime(rule["last_triggered_at"]) do
      {:ok, last_triggered_at} -> DateTime.diff(now, last_triggered_at, :second) < cooldown
      _ -> false
    end
  end

  defp presence_detected?(payload) do
    Map.get(payload, "presence") == true or Map.get(payload, "pir_detection") == true
  end

  defp notification_text(rule, friendly_name, payload, metadata, now) do
    [
      "Presence detected at #{friendly_name}.",
      "Time: #{DateTime.to_iso8601(now)}",
      maybe_temperature(payload),
      maybe_humidity(payload),
      maybe_illuminance(payload),
      maybe_linkquality(payload),
      maybe_topic(metadata),
      "Alert: #{rule["id"]} presence until #{format_until(rule["ends_at"])}",
      "Cooldown: #{format_duration(rule["cooldown_seconds"] || 900)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp maybe_temperature(%{"temperature" => c}) when is_number(c) do
    f = c * 9 / 5 + 32
    "Temperature: #{format_number(f, 1)}°F"
  end

  defp maybe_temperature(_payload), do: nil

  defp maybe_humidity(%{"humidity" => humidity}) when is_number(humidity),
    do: "Humidity: #{format_number(humidity, 1)}%"

  defp maybe_humidity(_payload), do: nil

  defp maybe_illuminance(%{"illuminance" => illuminance}) when is_number(illuminance),
    do: "Illuminance: #{format_number(illuminance, 0)} lx"

  defp maybe_illuminance(_payload), do: nil

  defp maybe_linkquality(%{"linkquality" => linkquality}) when is_number(linkquality),
    do: "Linkquality: #{format_number(linkquality, 0)}"

  defp maybe_linkquality(_payload), do: nil

  defp maybe_topic(metadata) do
    case Map.get(metadata, "topic") || Map.get(metadata, :topic) do
      nil -> nil
      topic -> "Topic: #{topic}"
    end
  end

  defp format_until(value) do
    case parse_datetime(value) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _ -> to_string(value)
    end
  end

  defp format_duration(seconds) when seconds >= 60 and rem(seconds, 60) == 0,
    do: "#{div(seconds, 60)}m"

  defp format_duration(seconds), do: "#{seconds}s"

  defp parse_datetime(nil), do: :error

  defp parse_datetime(%DateTime{} = datetime), do: {:ok, datetime}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp format_number(number, precision) do
    :erlang.float_to_binary(number / 1, decimals: precision)
  end
end

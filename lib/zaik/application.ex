defmodule Zaik.Application do
  @moduledoc """
  The Zaik Application.

  This module defines the root supervision tree for the Zaik system.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Zaik.Clock,
        telemetry_store_child(),
        Zaik.TaskStore,
        Zaik.SessionStore,
        Zaik.TaskQueue,
        Zaik.Home.DeviceStore,
        home_history_child(),
        zigbee2mqtt_bootstrapper_child(),
        mqtt_child(),
        {Registry, keys: :unique, name: Zaik.Agent.Registry},
        Zaik.Agent.DynamicSupervisor,
        Zaik.Dispatcher,
        watchdog_child(),
        scheduler_child(),
        Zaik.Agent.Supervisor,
        signal_poller_child(),
        telegram_poller_child()
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: Zaik.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp telemetry_store_child do
    config = Zaik.TelemetryStore.config()

    if config.enabled do
      {Zaik.TelemetryStore, Map.to_list(config)}
    end
  end

  defp home_history_child do
    config = Zaik.Home.HistoryStore.config()

    if config.enabled do
      {Zaik.Home.HistoryStore, Map.to_list(config)}
    end
  end

  defp zigbee2mqtt_bootstrapper_child do
    config = Zaik.Home.Zigbee2MQTT.config()

    if config.bootstrap_state? do
      {Zaik.Home.Zigbee2MQTTBootstrapper, Map.to_list(config)}
    end
  end

  defp mqtt_child do
    config = Zaik.MQTT.Client.config()

    if config.enabled do
      {Zaik.MQTT.Client, Map.to_list(config)}
    end
  end

  defp watchdog_child do
    config = Application.get_env(:zaik, :watchdog, [])

    if Keyword.get(config, :enabled, true) do
      {Zaik.TaskWatchdog, config}
    end
  end

  defp scheduler_child do
    config = Zaik.Scheduler.config()

    if config.enabled do
      {Zaik.Scheduler, Map.to_list(config)}
    end
  end

  defp signal_poller_child do
    signal_config = Zaik.Messaging.SignalClient.config()

    if signal_config.enabled do
      {Zaik.Messaging.SignalPoller, Map.to_list(signal_config)}
    end
  end

  defp telegram_poller_child do
    telegram_config = Zaik.Messaging.TelegramClient.config()

    if telegram_config.enabled do
      {Zaik.Messaging.TelegramPoller, Map.to_list(telegram_config)}
    end
  end
end

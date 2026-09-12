defmodule Zaik.Application do
  @moduledoc """
  The Zaik Application.

  This module defines the root supervision tree for the Zaik system.
  """

  use Application

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: Zaik.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  @doc """
  Build the runtime supervision composition from current domain and adapter config.
  """
  def children do
    [
      Zaik.Clock,
      domain_child(:operations, telemetry_store_child()),
      {Task.Supervisor, name: Zaik.Tools.TaskSupervisor},
      domain_child(:operations, Zaik.TaskStore),
      domain_child(:operations, Zaik.SessionStore),
      domain_child(:operations, Zaik.TaskQueue),
      domain_child(:home, Zaik.Home.EventBus),
      domain_child(:home, Zaik.Home.DeviceStore),
      domain_child(:home, home_history_child()),
      domain_child(:home, occupancy_tracker_child()),
      domain_child(:home, device_preset_store_child()),
      domain_child(:home, home_action_ledger_child()),
      domain_child(:home, home_action_verifier_child()),
      domain_child(:home, autonomy_decision_store_child()),
      domain_child(:home, autonomy_manual_override_store_child()),
      domain_child(:home, autonomy_desired_state_store_child()),
      domain_child(:home, autonomy_engine_child()),
      domain_child(:home, alerts_rule_store_child()),
      domain_child(:home, alerts_engine_child()),
      domain_adapter_child(:home, :zigbee2mqtt, zigbee2mqtt_bootstrapper_child()),
      adapter_child(:mqtt, mqtt_child()),
      domain_child(:agents, {Registry, keys: :unique, name: Zaik.Agent.Registry}),
      domain_child(:agents, Zaik.Agent.DynamicSupervisor),
      domain_child(:operations, Zaik.Dispatcher),
      domain_child(:operations, watchdog_child()),
      domain_child(:operations, scheduler_child()),
      domain_child(:agents, Zaik.Agent.Supervisor),
      domain_adapter_child(:messaging, :signal, signal_poller_child()),
      domain_adapter_child(:messaging, :telegram, telegram_poller_child())
      | List.wrap(Application.get_env(:zaik, :additional_children, []))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp domain_child(domain, child), do: if(runtime_enabled?(:domains, domain), do: child)
  defp adapter_child(adapter, child), do: if(runtime_enabled?(:adapters, adapter), do: child)

  defp domain_adapter_child(domain, adapter, child) do
    if runtime_enabled?(:domains, domain) and runtime_enabled?(:adapters, adapter), do: child
  end

  defp runtime_enabled?(group, key) do
    group
    |> then(&Application.get_env(:zaik, &1, []))
    |> Keyword.get(key, true)
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

  defp occupancy_tracker_child do
    config = Zaik.Home.Autonomy.Engine.config()

    if config.enabled do
      {Zaik.Home.OccupancyTracker, absence_debounce_ms: config.occupancy_absence_debounce_ms}
    end
  end

  defp device_preset_store_child do
    config = Zaik.Home.DevicePresetStore.config()

    if config.enabled do
      {Zaik.Home.DevicePresetStore, Map.to_list(config)}
    end
  end

  defp home_action_ledger_child do
    config = Zaik.Home.ActionLedger.config()

    if config.enabled do
      {Zaik.Home.ActionLedger, Map.to_list(config)}
    end
  end

  defp home_action_verifier_child do
    config = Zaik.Home.ActionVerifier.config()

    if config.enabled do
      {Zaik.Home.ActionVerifier, Map.to_list(config)}
    end
  end

  defp autonomy_decision_store_child do
    config = Zaik.Home.Autonomy.Engine.config()

    if config.enabled do
      {Zaik.Home.Autonomy.DecisionStore, db_path: config.decision_db_path}
    end
  end

  defp autonomy_manual_override_store_child do
    config = Zaik.Home.Autonomy.Engine.config()

    if config.enabled do
      {Zaik.Home.Autonomy.ManualOverrideStore, db_path: config.decision_db_path}
    end
  end

  defp autonomy_desired_state_store_child do
    config = Zaik.Home.Autonomy.Engine.config()

    if config.enabled do
      {Zaik.Home.Autonomy.DesiredStateStore, db_path: config.decision_db_path}
    end
  end

  defp autonomy_engine_child do
    config = Zaik.Home.Autonomy.Engine.config()

    if config.enabled do
      {Zaik.Home.Autonomy.Engine, Map.to_list(config)}
    end
  end

  defp alerts_rule_store_child do
    config = Zaik.Alerts.RuleStore.config()

    if config.enabled do
      {Zaik.Alerts.RuleStore, Map.to_list(config)}
    end
  end

  defp alerts_engine_child do
    config = Zaik.Alerts.RuleStore.config()

    if config.enabled do
      Zaik.Alerts.Engine
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

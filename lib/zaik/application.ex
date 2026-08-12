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
        Zaik.TaskStore,
        Zaik.SessionStore,
        Zaik.TaskQueue,
        {Registry, keys: :unique, name: Zaik.Agent.Registry},
        Zaik.Agent.DynamicSupervisor,
        Zaik.Dispatcher,
        watchdog_child(),
        Zaik.Agent.Supervisor,
        signal_poller_child()
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: Zaik.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp watchdog_child do
    config = Application.get_env(:zaik, :watchdog, [])

    if Keyword.get(config, :enabled, true) do
      {Zaik.TaskWatchdog, config}
    end
  end

  defp signal_poller_child do
    signal_config = Zaik.Messaging.SignalClient.config()

    if signal_config.enabled do
      {Zaik.Messaging.SignalPoller, Map.to_list(signal_config)}
    end
  end
end

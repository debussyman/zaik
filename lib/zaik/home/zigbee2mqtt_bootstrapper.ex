defmodule Zaik.Home.Zigbee2MQTTBootstrapper do
  @moduledoc """
  One-shot startup bootstrap for Zigbee2MQTT's local state file.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @impl true
  def init(opts) do
    {:ok, opts, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, opts) do
    case Zaik.Home.Zigbee2MQTT.bootstrap_from_files(opts) do
      {:ok, count} -> Logger.info("Bootstrapped #{count} Zigbee2MQTT device states")
      :ignored -> :ok
      {:error, reason} -> Logger.warning("Zigbee2MQTT bootstrap failed: #{inspect(reason)}")
    end

    {:noreply, opts}
  end
end

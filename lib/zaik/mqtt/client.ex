defmodule Zaik.MQTT.Client do
  @moduledoc """
  OTP wrapper around local Mosquitto CLI tools for MQTT integration.

  Zaik already carries `mosquitto` in the Nix dev shell. Using
  `mosquitto_sub`/`mosquitto_pub` keeps this first local home-automation slice
  lightweight and avoids native MQTT client dependencies.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def config do
    configured = Application.get_env(:zaik, :mqtt, [])

    %{
      enabled: env_bool("ZAIK_MQTT_ENABLED", Keyword.get(configured, :enabled, true)),
      host: System.get_env("ZAIK_MQTT_HOST") || Keyword.get(configured, :host, "localhost"),
      port: env_integer("ZAIK_MQTT_PORT", Keyword.get(configured, :port, 1883)),
      client_id:
        System.get_env("ZAIK_MQTT_CLIENT_ID") || Keyword.get(configured, :client_id, "zaik"),
      topics: Keyword.get(configured, :topics, ["zigbee2mqtt/#"]),
      reconnect_interval_ms:
        env_integer(
          "ZAIK_MQTT_RECONNECT_INTERVAL_MS",
          Keyword.get(configured, :reconnect_interval_ms, 5_000)
        ),
      sub_path:
        System.get_env("ZAIK_MOSQUITTO_SUB") ||
          Keyword.get(configured, :sub_path, "mosquitto_sub"),
      pub_path:
        System.get_env("ZAIK_MOSQUITTO_PUB") ||
          Keyword.get(configured, :pub_path, "mosquitto_pub")
    }
  end

  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  def connected?(server \\ __MODULE__) do
    case status(server) do
      %{connected?: connected?} -> connected?
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  def publish(topic, payload, opts \\ []) do
    publish(__MODULE__, topic, payload, opts)
  end

  def publish(server, topic, payload, opts) do
    GenServer.call(server, {:publish, topic, payload, opts})
  end

  @impl true
  def init(opts) do
    cfg = Map.merge(config(), Map.new(opts))

    state = %{
      config: cfg,
      port: nil,
      connected?: false,
      last_error: nil,
      last_connected_at: nil,
      subscriptions: []
    }

    if cfg.enabled do
      {:ok, state, {:continue, :connect}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:connect, state), do: connect(state)

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      enabled: state.config.enabled,
      host: state.config.host,
      port: state.config.port,
      topics: state.config.topics,
      connected?: state.connected?,
      last_error: state.last_error,
      last_connected_at: state.last_connected_at,
      subscriptions: state.subscriptions
    }

    {:reply, status, state}
  end

  def handle_call({:publish, topic, payload, opts}, _from, state) do
    {:reply, do_publish(state.config, topic, payload, opts), state}
  end

  @impl true
  def handle_info(:connect, state), do: connect(state)

  def handle_info({_port, {:data, {:eol, line}}}, state) when is_binary(line) do
    handle_sub_line(line)
    {:noreply, state}
  end

  def handle_info({_port, {:data, {:noeol, line}}}, state) when is_binary(line) do
    handle_sub_line(line)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    reason = {:mosquitto_sub_exit, status}
    Logger.warning("MQTT subscription process exited: #{inspect(reason)}")

    state =
      state
      |> mark_disconnected(reason)
      |> Map.put(:port, nil)
      |> schedule_reconnect()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
    :ok
  end

  defp connect(%{config: %{enabled: false}} = state), do: {:noreply, state}

  defp connect(state) do
    close_port(state.port)
    cfg = state.config

    case sub_executable(cfg) do
      nil ->
        state =
          state
          |> mark_disconnected({:missing_executable, cfg.sub_path})
          |> Map.put(:port, nil)
          |> schedule_reconnect()

        {:noreply, state}

      executable ->
        args = sub_args(cfg)

        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            {:args, args},
            {:line, 5_000_000}
          ])

        Logger.info("MQTT subscribing via #{executable} #{Enum.join(args, " ")}")

        {:noreply,
         %{
           state
           | port: port,
             connected?: true,
             last_error: nil,
             last_connected_at: DateTime.utc_now(),
             subscriptions: cfg.topics
         }}
    end
  rescue
    error ->
      Logger.warning("MQTT subscription failed: #{Exception.message(error)}")

      state =
        state
        |> mark_disconnected(Exception.message(error))
        |> Map.put(:port, nil)
        |> schedule_reconnect()

      {:noreply, state}
  end

  defp do_publish(cfg, topic, payload, opts) do
    case pub_executable(cfg) do
      nil ->
        {:error, {:missing_executable, cfg.pub_path}}

      executable ->
        args =
          [
            "-h",
            cfg.host,
            "-p",
            to_string(cfg.port),
            "-i",
            publish_client_id(cfg),
            "-t",
            to_string(topic),
            "-m",
            payload_string(payload)
          ] ++
            retain_args(opts)

        case System.cmd(executable, args, stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:mosquitto_pub_exit, status, String.trim(output)}}
        end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp handle_sub_line(line) do
    case String.split(line, "\t", parts: 2) do
      [topic, payload] ->
        Zaik.Home.Zigbee2MQTT.handle_publish(topic, payload)

      _ ->
        Logger.debug("Ignoring MQTT subscription line without tab delimiter")
        :ignored
    end
  end

  defp sub_args(cfg) do
    ["-h", cfg.host, "-p", to_string(cfg.port), "-i", cfg.client_id]
    |> Kernel.++(topic_args(cfg.topics))
    |> Kernel.++(["-F", "%t\t%p"])
  end

  defp topic_args(topics) do
    Enum.flat_map(topics, fn topic -> ["-t", topic] end)
  end

  defp retain_args(opts) do
    if Keyword.get(opts, :retain, false), do: ["-r"], else: []
  end

  defp payload_string(payload) when is_binary(payload), do: payload
  defp payload_string(payload), do: Jason.encode!(payload)

  defp publish_client_id(cfg),
    do: cfg.client_id <> "-pub-" <> Integer.to_string(System.unique_integer([:positive]))

  defp sub_executable(cfg), do: System.find_executable(cfg.sub_path)
  defp pub_executable(cfg), do: System.find_executable(cfg.pub_path)

  defp close_port(nil), do: :ok

  defp close_port(port) when is_port(port) do
    Port.close(port)
  catch
    :error, _ -> :ok
  end

  defp mark_disconnected(state, reason) do
    %{state | connected?: false, last_error: inspect(reason), subscriptions: []}
  end

  defp schedule_reconnect(%{config: %{enabled: false}} = state), do: state

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect, state.config.reconnect_interval_ms)
    state
  end

  defp env_bool(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> value |> String.downcase() |> then(&(&1 in ["1", "true", "yes", "on"]))
    end
  end

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> default
        end
    end
  end
end

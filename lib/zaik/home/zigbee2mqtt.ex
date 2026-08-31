defmodule Zaik.Home.Zigbee2MQTT do
  @moduledoc """
  Translates Zigbee2MQTT MQTT topics into Zaik home device state.
  """

  @behaviour Zaik.MQTT.Handler

  require Logger

  def config do
    configured = Application.get_env(:zaik, :zigbee2mqtt, [])

    %{
      base_topic: Keyword.get(configured, :base_topic, "zigbee2mqtt"),
      device_store: Keyword.get(configured, :device_store, Zaik.Home.DeviceStore),
      history_store: Keyword.get(configured, :history_store, Zaik.Home.HistoryStore),
      bootstrap_state?: Keyword.get(configured, :bootstrap_state?, true),
      data_dir:
        System.get_env("ZAIK_ZIGBEE2MQTT_DATA_DIR") ||
          Keyword.get(configured, :data_dir, "~/.local/share/zigbee2mqtt/data")
    }
  end

  def handle_publish(topic, payload, opts \\ []) do
    cfg = Map.merge(config(), Map.new(opts))

    with {:ok, topic} <- normalize_binary(topic),
         :ok <- interested_topic?(topic, cfg.base_topic),
         {:ok, payload} <- normalize_binary(payload),
         {:ok, decoded} <- decode_payload(payload) do
      route_publish(topic, decoded, cfg)
    else
      :ignore ->
        :ignored

      {:error, reason} ->
        Logger.debug("Ignoring Zigbee2MQTT publish: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp interested_topic?(topic, base_topic) do
    prefix = String.trim_trailing(base_topic, "/") <> "/"

    cond do
      not String.starts_with?(topic, prefix) ->
        :ignore

      topic == prefix <> "bridge/devices" ->
        :ok

      String.starts_with?(topic, prefix <> "bridge/") ->
        :ignore

      true ->
        :ok
    end
  end

  def bootstrap_from_files(opts \\ []) do
    cfg = Map.merge(config(), Map.new(opts))

    if cfg.bootstrap_state? do
      data_dir = expand_path(cfg.data_dir)
      state_path = Path.join(data_dir, "state.json")
      config_path = Path.join(data_dir, "configuration.yaml")
      database_path = Path.join(data_dir, "database.db")

      with {:ok, state_by_ieee} <- read_json_file(state_path) do
        friendly_by_ieee = read_friendly_names(config_path)
        metadata_by_ieee = read_database_metadata(database_path)

        Enum.each(state_by_ieee, fn {ieee, payload} ->
          friendly_name = Map.get(friendly_by_ieee, ieee, ieee)

          metadata =
            metadata_by_ieee
            |> Map.get(ieee, %{})
            |> Map.merge(%{
              "source" => "zigbee2mqtt_state_file",
              "ieee_address" => ieee,
              "topic" => cfg.base_topic <> "/" <> friendly_name
            })

          if is_map(payload) do
            Zaik.Home.DeviceStore.upsert_device(
              cfg.device_store,
              friendly_name,
              payload,
              metadata
            )

            record_history(cfg.history_store, friendly_name, payload, metadata)
          end
        end)

        {:ok, map_size(state_by_ieee)}
      else
        {:error, :enoent} -> :ignored
        {:error, reason} -> {:error, reason}
      end
    else
      :ignored
    end
  end

  defp route_publish(topic, decoded, %{base_topic: base_topic, device_store: store} = cfg) do
    prefix = String.trim_trailing(base_topic, "/") <> "/"

    cond do
      topic == base_topic ->
        :ignored

      not String.starts_with?(topic, prefix) ->
        :ignored

      true ->
        relative = String.replace_prefix(topic, prefix, "")
        route_relative(relative, decoded, store, Map.get(cfg, :history_store), topic)
    end
  end

  defp route_relative("bridge/devices", devices, store, _history_store, _topic)
       when is_list(devices) do
    devices
    |> Enum.reject(&coordinator?/1)
    |> Enum.each(fn device ->
      friendly_name = Map.get(device, "friendly_name") || Map.get(device, "friendlyName")

      if is_binary(friendly_name) and friendly_name != "" do
        definition = Map.get(device, "definition") || %{}

        Zaik.Home.DeviceStore.upsert_metadata(store, friendly_name, %{
          "ieee_address" => Map.get(device, "ieee_address") || Map.get(device, "ieeeAddr"),
          "model_id" =>
            Map.get(device, "model_id") || Map.get(device, "modelId") ||
              Map.get(definition, "model"),
          "manufacturer" =>
            Map.get(device, "manufacturer") || Map.get(device, "manufacturerName") ||
              Map.get(definition, "vendor"),
          "description" => Map.get(definition, "description"),
          "source" => "zigbee2mqtt"
        })
      end
    end)

    :ok
  end

  defp route_relative("bridge/" <> _bridge_topic, _decoded, _store, _history_store, _topic),
    do: :ignored

  defp route_relative(relative, decoded, store, history_store, topic) when is_map(decoded) do
    cond do
      relative == "" ->
        :ignored

      String.ends_with?(relative, "/set") ->
        :ignored

      String.ends_with?(relative, "/availability") ->
        :ignored

      true ->
        friendly_name = relative

        metadata = %{
          "source" => "zigbee2mqtt",
          "topic" => topic
        }

        with {:ok, device} <-
               Zaik.Home.DeviceStore.upsert_device(store, friendly_name, decoded, metadata) do
          record_history(history_store, device.friendly_name, device.payload, device.metadata)
          evaluate_alerts(device.friendly_name, device.payload, device.metadata)
          {:ok, device}
        end
    end
  end

  defp route_relative(_relative, _decoded, _store, _history_store, _topic), do: :ignored

  defp record_history(nil, _friendly_name, _payload, _metadata), do: :ok

  defp record_history(history_store, friendly_name, payload, metadata) do
    Zaik.Home.HistoryStore.record_device(history_store, friendly_name, payload, metadata)
    :ok
  rescue
    error ->
      Logger.debug("Failed to record home history: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("Failed to record home history: #{inspect(reason)}")
      :ok
  end

  defp evaluate_alerts(friendly_name, payload, metadata) do
    if Process.whereis(Zaik.Alerts.Engine) do
      Zaik.Alerts.Engine.evaluate_device_update(friendly_name, payload, metadata)
    end

    :ok
  rescue
    error ->
      Logger.debug("Failed to evaluate home alerts: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("Failed to evaluate home alerts: #{inspect(reason)}")
      :ok
  end

  defp coordinator?(device) do
    String.downcase(to_string(Map.get(device, "type", ""))) == "coordinator"
  end

  defp read_json_file(path) do
    case File.read(path) do
      {:ok, contents} -> Jason.decode(contents)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_friendly_names(path) do
    case File.read(path) do
      {:ok, contents} -> parse_friendly_names(contents)
      {:error, _reason} -> %{}
    end
  end

  defp parse_friendly_names(contents) do
    contents
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, fn line, {acc, current_ieee} ->
      case Regex.run(~r/^\s*['\"]?(0x[0-9a-fA-F]+)['\"]?:\s*$/, line) do
        [_, ieee] ->
          {acc, ieee}

        nil ->
          case {current_ieee, Regex.run(~r/^\s+friendly_name:\s*(.+?)\s*$/, line)} do
            {ieee, [_, friendly_name]} when is_binary(ieee) ->
              {Map.put(acc, ieee, strip_yaml_value(friendly_name)), ieee}

            _ ->
              {acc, current_ieee}
          end
      end
    end)
    |> elem(0)
  end

  defp strip_yaml_value(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp read_database_metadata(path) do
    case File.read(path) do
      {:ok, contents} -> parse_database_metadata(contents)
      {:error, _reason} -> %{}
    end
  end

  defp parse_database_metadata(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case Jason.decode(line) do
        {:ok, %{"type" => "EndDevice", "ieeeAddr" => ieee} = device} ->
          Map.put(acc, ieee, %{
            "manufacturer" => Map.get(device, "manufName"),
            "model_id" => Map.get(device, "modelId"),
            "power_source" => Map.get(device, "powerSource"),
            "last_seen" => Map.get(device, "lastSeen"),
            "interview_state" => Map.get(device, "interviewState")
          })

        _ ->
          acc
      end
    end)
  end

  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)

  defp decode_payload(""), do: :ignore

  defp decode_payload(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  defp normalize_binary(value) when is_binary(value), do: {:ok, value}
  defp normalize_binary(value) when is_list(value), do: {:ok, List.to_string(value)}
  defp normalize_binary(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize_binary(value), do: {:error, {:not_binary, value}}
end

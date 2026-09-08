defmodule Zaik.Home.Blinds do
  @moduledoc """
  Deterministic read/control layer for Zigbee2MQTT window coverings.

  This module deliberately keeps control narrow and validated: only known blind
  devices can be addressed, positions are bounded to 0..100, and state commands
  are limited to Zigbee2MQTT's exposed `OPEN`, `CLOSE`, and `STOP` values.
  """

  @states %{
    "open" => "OPEN",
    "opened" => "OPEN",
    "up" => "OPEN",
    "close" => "CLOSE",
    "closed" => "CLOSE",
    "down" => "CLOSE",
    "stop" => "STOP",
    "halt" => "STOP"
  }

  @stop_words ~w(the a an in on at of to for bedroom room blind blinds shade shades curtain curtains window windows)

  def config do
    z2m = Application.get_env(:zaik, :zigbee2mqtt, [])
    configured = Application.get_env(:zaik, :blinds, [])

    %{
      base_topic:
        Keyword.get(configured, :base_topic, Keyword.get(z2m, :base_topic, "zigbee2mqtt")),
      device_store: Keyword.get(configured, :device_store, Zaik.Home.DeviceStore),
      preset_store: Keyword.get(configured, :preset_store, Zaik.Home.DevicePresetStore),
      mqtt_client: Keyword.get(configured, :mqtt_client, Zaik.MQTT.Client)
    }
  end

  def list(query \\ nil, opts \\ []) do
    cfg = Map.merge(config(), Map.new(opts))

    cfg.device_store
    |> Zaik.Home.DeviceStore.list_devices()
    |> Enum.filter(&blind?/1)
    |> filter_query(query)
    |> Enum.sort_by(&String.downcase(&1.friendly_name))
  end

  def get(query, opts \\ []) when is_binary(query) do
    case list(query, opts) do
      [device] -> {:ok, device}
      [] -> {:error, :not_found}
      devices -> {:error, {:ambiguous, Enum.map(devices, & &1.friendly_name)}}
    end
  end

  def capture(query, preset_name, context \\ %{}, opts \\ []) do
    cfg = Map.merge(config(), Map.new(opts))

    with {:ok, device} <- get(query, opts),
         {:ok, position} <- current_position(device),
         {:ok, preset} <-
           Zaik.Home.DevicePresetStore.put(
             device.friendly_name,
             preset_name,
             "cover",
             %{"position" => position},
             %{
               source: "capture",
               created_by: actor_from_context(context),
               metadata: %{"captured_payload" => device.payload}
             },
             cfg.preset_store
           ) do
      {:ok, preset}
    end
  end

  def control(query, target, opts \\ []) when is_binary(query) do
    cfg = Map.merge(config(), Map.new(opts))

    with {:ok, device} <- get(query, opts),
         {:ok, payload} <- control_payload(device, target, cfg),
         :ok <- publish(cfg.mqtt_client, set_topic(device, cfg), payload) do
      {:ok,
       %{
         device: device,
         topic: set_topic(device, cfg),
         payload: payload,
         requested_at: DateTime.utc_now()
       }}
    end
  end

  def blind?(%{friendly_name: friendly_name, payload: payload, metadata: metadata}) do
    text =
      [
        friendly_name,
        Map.get(metadata, "description"),
        Map.get(metadata, "model_id"),
        Map.get(metadata, "manufacturer")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> normalize_text()

    cond do
      Regex.match?(
        ~r/\b(blind|blinds|shade|shades|cover|window covering|curtain|curtains)\b/,
        text
      ) ->
        true

      Map.has_key?(payload, "position") and Map.has_key?(payload, "state") ->
        true

      Map.has_key?(payload, "position") and text =~ "smartwings" ->
        true

      true ->
        false
    end
  end

  def blind?(_device), do: false

  def current_position(%{payload: payload}) do
    payload
    |> first_value(["position", "current_position", "currentPositionLiftPercentage"])
    |> normalize_position()
  end

  def status(device) do
    payload = device.payload

    %{
      friendly_name: device.friendly_name,
      position: current_position(device) |> unwrap_ok(),
      state: first_value(payload, ["state", "moving", "running", "motor_state"]),
      battery: first_value(payload, ["battery", "battery_percentage", "batteryPercent"]),
      linkquality: first_value(payload, ["linkquality"]),
      updated_at: device.updated_at
    }
  end

  def target_from_text(text) when is_binary(text) do
    value = String.trim(text)
    downcased = normalize_text(value)

    cond do
      Map.has_key?(@states, downcased) ->
        {:ok, {:state, Map.fetch!(@states, downcased)}}

      integer_string?(value) ->
        normalize_position(value) |> then(&with {:ok, int} <- &1, do: {:ok, {:position, int}})

      value == "" ->
        {:error, :empty_target}

      true ->
        {:ok, {:preset, value}}
    end
  end

  defp control_payload(_device, {:position, position}, _cfg) do
    with {:ok, position} <- normalize_position(position), do: {:ok, %{"position" => position}}
  end

  defp control_payload(_device, {:state, "CLOSE"}, _cfg), do: {:ok, %{"position" => 100}}
  defp control_payload(_device, {:state, "OPEN"}, _cfg), do: {:ok, %{"position" => 0}}
  defp control_payload(_device, {:state, "STOP"}, _cfg), do: {:ok, %{"state" => "STOP"}}

  defp control_payload(device, {:preset, preset_name}, cfg) do
    with {:ok, preset} <-
           Zaik.Home.DevicePresetStore.get(
             device.friendly_name,
             preset_name,
             [capability: "cover"],
             cfg.preset_store
           ),
         target when is_map(target) <- preset["target"],
         {:ok, payload} <- validate_cover_target(target) do
      {:ok, payload}
    else
      nil -> {:error, {:preset_not_found, preset_name}}
      {:error, :not_found} -> {:error, {:preset_not_found, preset_name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp control_payload(_device, _target, _cfg), do: {:error, :invalid_target}

  defp validate_cover_target(%{"position" => position}) do
    with {:ok, position} <- normalize_position(position), do: {:ok, %{"position" => position}}
  end

  defp validate_cover_target(%{"state" => "CLOSE"}), do: {:ok, %{"position" => 100}}
  defp validate_cover_target(%{"state" => "OPEN"}), do: {:ok, %{"position" => 0}}
  defp validate_cover_target(%{"state" => "STOP"}), do: {:ok, %{"state" => "STOP"}}

  defp validate_cover_target(_target), do: {:error, :invalid_target}

  defp publish(mqtt_client, topic, payload) do
    apply(mqtt_client, :publish, [topic, payload, []])
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp set_topic(device, cfg) do
    base = String.trim_trailing(cfg.base_topic, "/")
    base <> "/" <> device.friendly_name <> "/set"
  end

  defp filter_query(devices, nil), do: devices
  defp filter_query(devices, ""), do: devices

  defp filter_query(devices, query) do
    query_tokens = tokens(query)

    Enum.filter(devices, fn device ->
      device_tokens = tokens(device.friendly_name)
      normalized_name = normalize_text(device.friendly_name)
      normalized_query = normalize_text(query)

      normalized_name =~ normalized_query or
        Enum.all?(query_tokens, &token_matches?(&1, device_tokens))
    end)
  end

  defp tokens(value) do
    value
    |> normalize_text()
    |> String.split(" ", trim: true)
    |> Enum.reject(&(&1 in @stop_words))
  end

  defp token_matches?(query_token, device_tokens) do
    Enum.any?(device_tokens, fn device_token ->
      device_token == query_token or String.starts_with?(device_token, query_token) or
        String.starts_with?(query_token, device_token)
    end)
  end

  defp first_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp first_value(_map, _keys), do: nil

  defp normalize_position(value) when is_integer(value) and value in 0..100, do: {:ok, value}

  defp normalize_position(value) when is_float(value),
    do: value |> round() |> normalize_position()

  defp normalize_position(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> normalize_position(int)
      _ -> {:error, :invalid_position}
    end
  end

  defp normalize_position(_value), do: {:error, :invalid_position}

  defp integer_string?(value) do
    case Integer.parse(String.trim(value)) do
      {_int, ""} -> true
      _ -> false
    end
  end

  defp unwrap_ok({:ok, value}), do: value
  defp unwrap_ok(_), do: nil

  defp actor_from_context(context) when is_map(context) do
    value =
      Map.get(context, :sender_id) || Map.get(context, "sender_id") || Map.get(context, :sender) ||
        Map.get(context, "sender")

    if is_nil(value), do: nil, else: to_string(value)
  end

  defp actor_from_context(_context), do: nil

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/['’]/, "")
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end

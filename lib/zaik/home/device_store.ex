defmodule Zaik.Home.DeviceStore do
  @moduledoc """
  In-memory latest-state store for home devices discovered via MQTT.

  The store intentionally keeps only the current known state in OTP memory for
  the first home-automation slice. MQTT/Zigbee2MQTT remain the source of truth,
  and retained MQTT messages repopulate this store after restarts. Reports with
  source timestamps older than current state, plus exact timestamped duplicates,
  are ignored so delivery order cannot regress the canonical snapshot.
  """

  use GenServer

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def upsert_device(server \\ __MODULE__, friendly_name, payload, metadata \\ %{})
      when is_binary(friendly_name) and is_map(payload) and is_map(metadata) do
    GenServer.call(server, {:upsert_device, friendly_name, payload, metadata})
  end

  def upsert_metadata(server \\ __MODULE__, friendly_name, metadata)
      when is_binary(friendly_name) and is_map(metadata) do
    GenServer.call(server, {:upsert_metadata, friendly_name, metadata})
  end

  def get_device(server \\ __MODULE__, query) when is_binary(query) do
    GenServer.call(server, {:get_device, query})
  end

  def find_device(server \\ __MODULE__, query) when is_binary(query) do
    GenServer.call(server, {:find_device, query})
  end

  def list_devices(server \\ __MODULE__) do
    GenServer.call(server, :list_devices)
  end

  def presence_devices(server \\ __MODULE__) do
    GenServer.call(server, :presence_devices)
  end

  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  @impl true
  def init(opts), do: {:ok, %{devices: %{}, clock: Keyword.get(opts, :clock)}}

  @impl true
  def handle_call({:upsert_device, friendly_name, payload, metadata}, _from, state) do
    friendly_name = String.trim(friendly_name)
    now = Zaik.Time.now(state.clock)

    existing = Map.get(state.devices, normalize(friendly_name), %{})
    existing_payload = Map.get(existing, :payload, %{})
    observed_at = source_observed_at(metadata, now)

    case report_disposition(existing, payload, observed_at) do
      :stale ->
        {:reply, {:ignored, :stale}, state}

      :duplicate ->
        {:reply, {:ignored, :duplicate}, state}

      :accept ->
        existing_metadata = Map.get(existing, :metadata, %{})
        merged_metadata = Map.merge(existing_metadata, metadata)

        device = %{
          friendly_name: friendly_name,
          payload: Map.merge(existing_payload, payload),
          metadata: merged_metadata,
          topic:
            Map.get(metadata, "topic") || Map.get(metadata, :topic) || Map.get(existing, :topic),
          first_seen_at: Map.get(existing, :first_seen_at, now),
          observed_at: observed_at,
          received_at: now,
          updated_at: now
        }

        state = put_device(state, device)
        {:reply, {:ok, device}, state}
    end
  end

  def handle_call({:upsert_metadata, friendly_name, metadata}, _from, state) do
    friendly_name = String.trim(friendly_name)
    now = Zaik.Time.now(state.clock)

    existing = Map.get(state.devices, normalize(friendly_name), %{})
    existing_payload = Map.get(existing, :payload, %{})
    existing_metadata = Map.get(existing, :metadata, %{})

    device = %{
      friendly_name: friendly_name,
      payload: existing_payload,
      metadata: Map.merge(existing_metadata, metadata),
      topic: Map.get(metadata, "topic") || Map.get(metadata, :topic) || Map.get(existing, :topic),
      first_seen_at: Map.get(existing, :first_seen_at, now),
      observed_at: Map.get(existing, :observed_at),
      received_at: Map.get(existing, :received_at),
      updated_at: Map.get(existing, :updated_at, now)
    }

    state = put_device(state, device)
    {:reply, {:ok, device}, state}
  end

  def handle_call({:get_device, query}, _from, state) do
    reply =
      case Map.fetch(state.devices, normalize(query)) do
        {:ok, device} -> {:ok, device}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:find_device, query}, _from, state) do
    normalized_query = normalize(query)

    reply =
      case Map.fetch(state.devices, normalized_query) do
        {:ok, device} ->
          {:ok, device}

        :error ->
          matches =
            state.devices
            |> Map.values()
            |> Enum.filter(fn device ->
              normalize(device.friendly_name) =~ normalized_query
            end)
            |> sort_devices()

          case matches do
            [device] -> {:ok, device}
            [] -> {:error, :not_found}
            devices -> {:error, {:ambiguous, Enum.map(devices, & &1.friendly_name)}}
          end
      end

    {:reply, reply, state}
  end

  def handle_call(:list_devices, _from, state) do
    {:reply, state.devices |> Map.values() |> sort_devices(), state}
  end

  def handle_call(:presence_devices, _from, state) do
    devices =
      state.devices
      |> Map.values()
      |> Enum.filter(fn device -> Map.has_key?(device.payload, "presence") end)
      |> sort_devices()

    {:reply, devices, state}
  end

  def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | devices: %{}}}

  defp put_device(state, device) do
    %{state | devices: Map.put(state.devices, normalize(device.friendly_name), device)}
  end

  defp sort_devices(devices), do: Enum.sort_by(devices, &String.downcase(&1.friendly_name))

  defp report_disposition(existing, payload, observed_at) do
    existing_observed_at = Map.get(existing, :observed_at)
    existing_payload = Map.get(existing, :payload, %{})

    cond do
      map_size(existing) == 0 ->
        :accept

      is_struct(existing_observed_at, DateTime) and is_nil(observed_at) ->
        :stale

      is_struct(existing_observed_at, DateTime) and is_struct(observed_at, DateTime) and
          DateTime.compare(observed_at, existing_observed_at) == :lt ->
        :stale

      is_struct(existing_observed_at, DateTime) and is_struct(observed_at, DateTime) and
        DateTime.compare(observed_at, existing_observed_at) == :eq and
          payload_already_present?(existing_payload, payload) ->
        :duplicate

      true ->
        :accept
    end
  end

  defp payload_already_present?(existing, incoming) do
    Enum.all?(incoming, fn {key, value} -> Map.get(existing, key) == value end)
  end

  defp source_observed_at(metadata, now) do
    value =
      Map.get(metadata, "observed_at") || Map.get(metadata, :observed_at) ||
        Map.get(metadata, "last_seen") || Map.get(metadata, :last_seen)

    case parse_datetime(value) do
      {:ok, observed_at} -> observed_at
      :error -> if bootstrap_metadata?(metadata), do: nil, else: now
    end
  end

  defp bootstrap_metadata?(metadata) do
    Map.get(metadata, "bootstrap") == true or Map.get(metadata, :bootstrap) == true or
      Map.get(metadata, "source") == "zigbee2mqtt_state_file" or
      Map.get(metadata, :source) == "zigbee2mqtt_state_file"
  end

  defp parse_datetime(%DateTime{} = value), do: {:ok, value}

  defp parse_datetime(value) when is_integer(value) do
    unit = if abs(value) > 9_999_999_999, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      _ ->
        case Integer.parse(value) do
          {integer, ""} -> parse_datetime(integer)
          _ -> :error
        end
    end
  end

  defp parse_datetime(_value), do: :error

  defp normalize(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end
end

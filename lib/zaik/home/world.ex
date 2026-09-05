defmodule Zaik.Home.World do
  @moduledoc """
  Adapter-neutral, typed view of the latest known home state.

  This module derives entities and capability state from `DeviceStore` without
  changing the adapter's raw payload. Historical analytics remain in
  `HistoryStore`; callers should use this world view for ordinary current-state
  reasoning so unrelated device types cannot mask one another.
  """

  alias Zaik.Home.{Capabilities.Registry, Entity}

  def entities(opts \\ []) do
    store = Keyword.get(opts, :device_store, Zaik.Home.DeviceStore)
    capability_opts = Keyword.get(opts, :capability_opts, [])

    store
    |> Zaik.Home.DeviceStore.list_devices()
    |> Enum.map(&to_entity(&1, capability_opts))
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  def find(query \\ nil, opts \\ []) do
    capability = Keyword.get(opts, :capability)

    entities(opts)
    |> filter_query(query)
    |> filter_capability(capability)
  end

  def get(query, opts \\ []) when is_binary(query) do
    matches = find(query, opts)

    case matches do
      [entity] -> {:ok, entity}
      [] -> {:error, :not_found}
      entities -> {:error, {:ambiguous, Enum.map(entities, & &1.name)}}
    end
  end

  def snapshot(query \\ nil, opts \\ []) do
    entities = find(query, opts)

    %{
      entities: Enum.map(entities, &public_entity/1),
      count: length(entities),
      generated_at: DateTime.utc_now()
    }
  end

  def public_entity(%Entity{} = entity) do
    %{
      id: entity.id,
      name: entity.name,
      area_id: entity.area_id,
      source: entity.source,
      capabilities: entity.capabilities,
      state: entity.state,
      observed_at: format_datetime(entity.observed_at),
      received_at: format_datetime(entity.received_at)
    }
  end

  defp to_entity(device, capability_opts) do
    detected = Registry.detected(device, capability_opts)

    %Entity{
      id: entity_id(device),
      name: device.friendly_name,
      area_id: area_id(device.metadata),
      source: metadata_value(device.metadata, :source),
      capabilities: Enum.map(detected, & &1.descriptor.id),
      state: Map.new(detected, &{&1.descriptor.id, &1.state}),
      observed_at: field_or_fallback(device, :observed_at, :updated_at),
      received_at: field_or_fallback(device, :received_at, :updated_at)
    }
  end

  defp field_or_fallback(map, key, fallback_key) do
    if Map.has_key?(map, key), do: Map.get(map, key), else: Map.get(map, fallback_key)
  end

  defp entity_id(device) do
    metadata = device.metadata || %{}

    metadata_value(metadata, :entity_id) || metadata_value(metadata, :ieee_address) ||
      metadata_value(metadata, :topic) || "device:" <> normalize(device.friendly_name)
  end

  defp area_id(metadata) do
    metadata_value(metadata, :area_id) || metadata_value(metadata, :area) ||
      metadata_value(metadata, :room)
  end

  defp metadata_value(metadata, key) do
    case Map.get(metadata, key) || Map.get(metadata, to_string(key)) do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp filter_query(entities, query) when query in [nil, ""], do: entities

  defp filter_query(entities, query) do
    normalized_query = normalize(query)
    lookup_query = normalize_lookup(query)

    Enum.filter(entities, fn entity ->
      normalize(entity.id) == normalized_query or
        normalize_lookup(entity.name) == lookup_query or
        String.contains?(normalize_lookup(entity.name), lookup_query) or
        fuzzy_tokens_match?(lookup_query, normalize_lookup(entity.name)) or
        String.contains?(normalize_lookup(entity.area_id || ""), lookup_query) or
        fuzzy_tokens_match?(lookup_query, normalize_lookup(entity.area_id || ""))
    end)
  end

  defp filter_capability(entities, nil), do: entities
  defp filter_capability(entities, ""), do: entities

  defp filter_capability(entities, capability) do
    capability = normalize_capability(capability)
    Enum.filter(entities, &(capability in &1.capabilities))
  end

  defp normalize_capability(capability)
       when capability in [
              "temperature_f",
              "temperature_c",
              "fahrenheit",
              "celsius",
              :temperature_f,
              :temperature_c
            ],
       do: "temperature"

  defp normalize_capability(capability), do: normalize(capability)

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(value), do: value

  defp fuzzy_tokens_match?(query, candidate) do
    query_tokens = String.split(query, " ", trim: true)
    candidate_tokens = String.split(candidate, " ", trim: true)

    query_tokens != [] and
      Enum.all?(query_tokens, fn query_token ->
        Enum.any?(candidate_tokens, fn candidate_token ->
          query_token == candidate_token or String.starts_with?(candidate_token, query_token) or
            String.starts_with?(query_token, candidate_token)
        end)
      end)
  end

  defp normalize_lookup(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/['’]/, "")
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.replace(~r/\s+/, " ")
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/['’]/, "")
    |> String.replace(~r/[^a-z0-9:_-]+/, " ")
    |> String.replace(~r/\s+/, " ")
  end
end

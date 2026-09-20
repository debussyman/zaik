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
    identities = identity_index(opts)

    store
    |> Zaik.Home.DeviceStore.list_devices()
    |> Enum.map(&to_entity(&1, capability_opts, identities))
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
    entities = Enum.map(find(query, opts), &public_entity/1)
    contract_opts = [capability_opts: Keyword.get(opts, :capability_opts, [])]
    contract_fingerprint = Zaik.Home.WorldContract.fingerprint(contract_opts)

    %{
      snapshot_id: snapshot_id(entities, contract_fingerprint),
      world_schema_version: Zaik.Home.WorldContract.schema_version(),
      world_contract_fingerprint: contract_fingerprint,
      entities: entities,
      count: length(entities),
      generated_at: Keyword.get(opts, :clock) |> Zaik.Time.now()
    }
  end

  def snapshot_id(public_entities, contract_fingerprint)
      when is_list(public_entities) and is_binary(contract_fingerprint) do
    %{world_contract_fingerprint: contract_fingerprint, entities: public_entities}
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def public_entity(%Entity{} = entity) do
    %{
      id: entity.id,
      name: entity.name,
      area_id: entity.area_id,
      aliases: entity.aliases,
      source: entity.source,
      capabilities: entity.capabilities,
      state: entity.state,
      observation: entity.observation,
      observed_at: format_datetime(entity.observed_at),
      received_at: format_datetime(entity.received_at)
    }
  end

  defp to_entity(device, capability_opts, identities) do
    detected = Registry.detected(device, capability_opts)
    id = entity_id(device)

    identity =
      Map.get(identities, id) || Map.get(identities, normalize(device.friendly_name)) || %{}

    %Entity{
      id: id,
      name: device.friendly_name,
      area_id: Map.get(identity, :area_id) || area_id(device.metadata),
      aliases: Map.get(identity, :aliases, []),
      source: metadata_value(device.metadata, :source),
      capabilities: Enum.map(detected, & &1.descriptor.id),
      state: Map.new(detected, &{&1.descriptor.id, &1.state}),
      observed_at: field_or_fallback(device, :observed_at, :updated_at),
      received_at: field_or_fallback(device, :received_at, :updated_at),
      observation: observation_semantics(device)
    }
  end

  defp observation_semantics(device) do
    observed_at = field_or_fallback(device, :observed_at, :updated_at)
    metadata = Map.get(device, :metadata) || %{}

    bootstrap? =
      metadata_value(metadata, :source) == "zigbee2mqtt_state_file" or
        Map.get(metadata, :bootstrap) == true or Map.get(metadata, "bootstrap") == true

    cond do
      is_struct(observed_at, DateTime) ->
        %{
          classification: "source_observation",
          freshness_eligible: true,
          freshness_reference: "observed_at",
          received_at_substitutes_for_observed_at: false
        }

      bootstrap? ->
        %{
          classification: "bootstrap_recovery",
          freshness_eligible: false,
          freshness_reference: nil,
          received_at_substitutes_for_observed_at: false
        }

      true ->
        %{
          classification: "unobserved",
          freshness_eligible: false,
          freshness_reference: nil,
          received_at_substitutes_for_observed_at: false
        }
    end
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
        Enum.any?(entity.aliases, fn alias_name ->
          normalize_lookup(alias_name) == lookup_query or
            String.contains?(normalize_lookup(alias_name), lookup_query)
        end) or
        String.contains?(normalize_lookup(entity.area_id || ""), lookup_query) or
        fuzzy_tokens_match?(lookup_query, normalize_lookup(entity.area_id || ""))
    end)
  end

  defp identity_index(opts) do
    store = Keyword.get(opts, :identity_store, Zaik.Home.HistoryStore)

    if is_pid(store) or Process.whereis(store) do
      store
      |> Zaik.Home.HistoryStore.list_devices()
      |> Enum.reduce(%{}, fn identity, acc ->
        acc
        |> Map.put(identity.id, identity)
        |> Map.put(normalize(identity.friendly_name), identity)
      end)
    else
      %{}
    end
  rescue
    _error -> %{}
  catch
    :exit, _reason -> %{}
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

  defp canonical(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical(value), do: value

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

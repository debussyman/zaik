defmodule Zaik.Home.EntityResolver do
  @moduledoc """
  Shared deterministic resolver for canonical home entities.

  It accepts structs or maps exposing `id`, `name`/`friendly_name`, `area_id`,
  and `aliases`. Capability, time-window, plural, and question words are removed
  by `Zaik.Home.Query` before matching, so every home read path can resolve the
  same entity set before applying capability-specific projection.
  """

  @version 1

  def version, do: @version

  def select(candidates, query) when is_list(candidates) and query in [nil, ""] do
    sort(candidates)
  end

  def select(candidates, query) when is_list(candidates) and is_binary(query) do
    case exact_matches(candidates, query) do
      [] -> select_normalized(candidates, query)
      exact -> sort(exact)
    end
  end

  def select(_candidates, _query), do: []

  def one(candidates, query) when is_list(candidates) do
    case select(candidates, query) do
      [candidate] -> {:ok, candidate}
      [] -> {:error, :not_found}
      matches -> {:error, {:ambiguous, Enum.map(matches, &display_name/1)}}
    end
  end

  defp select_normalized(candidates, query) do
    case Zaik.Home.Query.entity_lookup(query) do
      nil ->
        []

      lookup ->
        normalized = normalize(lookup)
        normalized_id = normalize_id(lookup)

        candidates
        |> Enum.filter(&matches?(&1, normalized, normalized_id))
        |> sort()
    end
  end

  defp exact_matches(candidates, query) do
    query_id = normalize_id(query)
    query_name = normalize(query)

    Enum.filter(candidates, fn candidate ->
      normalize_id(value(candidate, :id)) == query_id or
        normalize(display_name(candidate)) == query_name or
        normalize(value(candidate, :area_id)) == query_name or
        Enum.any?(List.wrap(value(candidate, :aliases)), &(normalize(&1) == query_name))
    end)
  end

  defp matches?(candidate, lookup, lookup_id) do
    id = candidate |> value(:id) |> normalize_id()
    name = candidate |> display_name() |> normalize()
    area = candidate |> value(:area_id) |> normalize()
    aliases = List.wrap(value(candidate, :aliases))

    id == lookup_id or name == lookup or String.contains?(name, lookup) or
      fuzzy_tokens_match?(lookup, name) or area == lookup or String.contains?(area, lookup) or
      fuzzy_tokens_match?(lookup, area) or
      Enum.any?(aliases, fn alias_name ->
        alias_name = normalize(alias_name)

        alias_name == lookup or String.contains?(alias_name, lookup) or
          fuzzy_tokens_match?(lookup, alias_name)
      end)
  end

  defp fuzzy_tokens_match?(query, candidate) do
    query_tokens = String.split(query, " ", trim: true)
    candidate_tokens = String.split(candidate, " ", trim: true)

    query_tokens != [] and candidate_tokens != [] and
      Enum.all?(query_tokens, fn query_token ->
        Enum.any?(candidate_tokens, fn candidate_token ->
          query_token == candidate_token or String.starts_with?(candidate_token, query_token) or
            String.starts_with?(query_token, candidate_token)
        end)
      end)
  end

  defp sort(candidates), do: Enum.sort_by(candidates, &String.downcase(display_name(&1)))

  defp display_name(candidate) do
    value(candidate, :name) || value(candidate, :friendly_name) || value(candidate, :id) || ""
  end

  defp normalize_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/['’]/, "")
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/['’]/, "")
    |> String.replace(~r/[^a-z0-9:_-]+/, " ")
    |> String.replace(~r/[_-]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp value(candidate, key) when is_map(candidate) do
    Map.get(candidate, key) || Map.get(candidate, to_string(key))
  end
end

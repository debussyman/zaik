defmodule Zaik.Home.Mirror.Scenario do
  @moduledoc """
  Versionable definition of one deterministic virtual-home evaluation scenario.
  """

  @enforce_keys [:id, :entities, :desired_state]
  defstruct [
    :id,
    :description,
    :now,
    version: 1,
    areas: [],
    entities: [],
    presets: [],
    desired_state: [],
    faults: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) do
    scenario = struct(__MODULE__, normalize_keys(attrs))

    with :ok <- non_empty(scenario.id, :missing_scenario_id),
         :ok <- list_of_maps(scenario.entities, :invalid_entities),
         :ok <- list_of_maps(scenario.areas, :invalid_areas),
         :ok <- list_of_maps(scenario.presets, :invalid_presets),
         :ok <- list_of_maps(scenario.desired_state, :invalid_desired_state),
         :ok <- validate_areas(scenario.areas),
         :ok <- validate_entities(scenario.entities),
         :ok <- validate_presets(scenario.presets),
         :ok <- validate_desired_state(scenario.desired_state),
         true <- is_map(scenario.faults) do
      {:ok, scenario}
    else
      false -> {:error, :invalid_faults}
      {:error, _reason} = error -> error
    end
  end

  def new(_attrs), do: {:error, :invalid_scenario}

  def new!(attrs) do
    case new(attrs) do
      {:ok, scenario} -> scenario
      {:error, reason} -> raise ArgumentError, "invalid mirror scenario: #{inspect(reason)}"
    end
  end

  def fingerprint(%__MODULE__{} = scenario) do
    scenario
    |> Map.from_struct()
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp validate_areas(areas) do
    invalid =
      Enum.find(areas, fn area ->
        not present?(area, :id) or not present?(area, :name)
      end)

    if invalid, do: {:error, {:invalid_area, invalid}}, else: :ok
  end

  defp validate_entities(entities) do
    invalid =
      Enum.find(entities, fn entity ->
        not present?(entity, :name) or not is_map(value(entity, :payload) || %{}) or
          not is_map(value(entity, :metadata) || %{})
      end)

    if invalid, do: {:error, {:invalid_entity, invalid}}, else: :ok
  end

  defp validate_presets(presets) do
    invalid =
      Enum.find(presets, fn preset ->
        not present?(preset, :device) or not present?(preset, :name) or
          not present?(preset, :capability) or not is_map(value(preset, :target))
      end)

    if invalid, do: {:error, {:invalid_preset, invalid}}, else: :ok
  end

  defp validate_desired_state(desired_state) do
    invalid =
      Enum.find(desired_state, fn target ->
        not present?(target, :device) or not present?(target, :capability) or
          not is_map(value(target, :target))
      end)

    if invalid, do: {:error, {:invalid_desired_state, invalid}}, else: :ok
  end

  defp list_of_maps(value, _error) when is_list(value) and value == [], do: :ok

  defp list_of_maps(value, error) when is_list(value) do
    if Enum.all?(value, &is_map/1), do: :ok, else: {:error, error}
  end

  defp list_of_maps(_value, error), do: {:error, error}

  defp non_empty(value, _error) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp non_empty(_value, error), do: {:error, error}
  defp present?(map, key), do: value(map, key) |> to_string() |> String.trim() != ""

  defp normalize_keys(attrs) do
    defaults = __MODULE__.__struct__()
    fields = Map.keys(defaults) -- [:__struct__]

    Map.new(fields, fn field ->
      {field, Map.get(attrs, field, Map.get(attrs, to_string(field), Map.get(defaults, field)))}
    end)
  end

  defp canonical(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

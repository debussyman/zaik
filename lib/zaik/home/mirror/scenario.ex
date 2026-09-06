defmodule Zaik.Home.Mirror.Scenario do
  @moduledoc """
  Versionable definition of one deterministic virtual-home evaluation scenario.
  """

  @enforce_keys [:id, :entities, :desired_state]
  defstruct [
    :id,
    :description,
    version: 1,
    now: ~U[2026-01-01 00:00:00Z],
    areas: [],
    entities: [],
    presets: [],
    home_history: [],
    ops_telemetry: %{},
    events: [],
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
         :ok <- list_of_maps(scenario.home_history, :invalid_home_history),
         :ok <- validate_home_history(scenario.home_history),
         :ok <- validate_ops_telemetry(scenario.ops_telemetry),
         :ok <- list_of_maps(scenario.events, :invalid_events),
         :ok <- validate_events(scenario.events),
         :ok <- list_of_maps(scenario.desired_state, :invalid_desired_state),
         :ok <- validate_now(scenario.now),
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

  defp validate_now(%DateTime{}), do: :ok
  defp validate_now(_now), do: {:error, :invalid_scenario_time}

  defp valid_datetime?(%DateTime{}), do: true

  defp valid_datetime?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp valid_datetime?(_value), do: false
  defp optional_datetime?(nil), do: true
  defp optional_datetime?(value), do: valid_datetime?(value)

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

  defp validate_home_history(history) do
    invalid =
      Enum.find(history, fn reading ->
        not present?(reading, :device) or not is_map(value(reading, :payload)) or
          not valid_datetime?(value(reading, :observed_at)) or
          not is_map(value(reading, :metadata) || %{})
      end)

    if invalid, do: {:error, {:invalid_home_history_reading, invalid}}, else: :ok
  end

  defp validate_ops_telemetry(telemetry) when is_map(telemetry) do
    allowed = ~w(messages tasks agent_chat_runs)a

    unknown =
      telemetry
      |> Map.keys()
      |> Enum.map(&normalize_section/1)
      |> Enum.reject(&(&1 in allowed))

    invalid =
      Enum.find(allowed, fn section ->
        value = Map.get(telemetry, section, Map.get(telemetry, to_string(section), []))
        not is_list(value) or not Enum.all?(value, &is_map/1)
      end)

    cond do
      unknown != [] ->
        {:error, {:unknown_ops_telemetry_sections, unknown}}

      invalid ->
        {:error, {:invalid_ops_telemetry_section, invalid}}

      invalid_row = invalid_ops_row(telemetry) ->
        {:error, invalid_row}

      true ->
        :ok
    end
  end

  defp validate_ops_telemetry(_telemetry), do: {:error, :invalid_ops_telemetry}

  defp invalid_ops_row(telemetry) do
    validators = %{
      messages: fn row -> present?(row, :content) and valid_datetime?(value(row, :created_at)) end,
      tasks: fn row ->
        present?(row, :id) and present?(row, :status) and
          valid_datetime?(value(row, :submitted_at)) and
          optional_datetime?(value(row, :started_at)) and
          optional_datetime?(value(row, :completed_at))
      end,
      agent_chat_runs: fn row ->
        present?(row, :id) and present?(row, :prompt) and present?(row, :status) and
          valid_datetime?(value(row, :created_at))
      end
    }

    Enum.find_value(validators, fn {section, valid?} ->
      rows = Map.get(telemetry, section, Map.get(telemetry, to_string(section), []))

      case Enum.find(rows, &(not valid?.(&1))) do
        nil -> nil
        row -> {:invalid_ops_telemetry_row, section, row}
      end
    end)
  end

  defp validate_events(events) do
    invalid =
      Enum.find(events, fn event ->
        normalize_event_type(value(event, :type)) != :state_report or
          not is_integer(value(event, :at_ms)) or value(event, :at_ms) < 0 or
          not present?(event, :device) or not is_map(value(event, :payload)) or
          not valid_datetime?(value(event, :observed_at))
      end)

    if invalid, do: {:error, {:invalid_event, invalid}}, else: :ok
  end

  defp normalize_event_type(:state_report), do: :state_report
  defp normalize_event_type("state_report"), do: :state_report
  defp normalize_event_type(_type), do: :unknown

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

  defp normalize_section(section) when is_atom(section), do: section

  defp normalize_section(section) when is_binary(section) do
    case section do
      "messages" -> :messages
      "tasks" -> :tasks
      "agent_chat_runs" -> :agent_chat_runs
      other -> other
    end
  end

  defp normalize_section(section), do: section

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

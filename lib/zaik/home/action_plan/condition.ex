defmodule Zaik.Home.ActionPlan.Condition do
  @moduledoc """
  Typed, deterministic observation condition for staged home plans.

  Conditions may compare one declared field from one registered canonical
  capability. They cannot contain model-authored code, functions, SQL, adapter
  payload paths, or arbitrary predicates.
  """

  @operators ~w(eq neq lt lte gt gte)
  @numeric_operators ~w(lt lte gt gte)
  @default_max_age_seconds 120
  @maximum_max_age_seconds 3_600

  @enforce_keys [
    :id,
    :entity_id,
    :device,
    :capability,
    :field,
    :operator,
    :expected,
    :max_age_seconds
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: binary(),
          entity_id: binary(),
          device: binary(),
          capability: binary(),
          field: binary(),
          operator: binary(),
          expected: number() | boolean() | binary(),
          max_age_seconds: pos_integer()
        }

  def preflight(condition, context \\ %{}, opts \\ [])

  def preflight(condition, context, opts) when is_map(condition) and is_map(context) do
    device = value(condition, :device) || value(condition, :entity_id)
    capability = normalize(value(condition, :capability))
    field = normalize(value(condition, :field))
    operator = normalize(value(condition, :operator))
    expected = value(condition, :value)
    max_age_seconds = value(condition, :max_age_seconds) || @default_max_age_seconds

    capability_opts =
      Keyword.get(opts, :capability_opts) || value(context, :capability_opts) || []

    world_opts =
      []
      |> put_if(:device_store, value(context, :device_store))
      |> put_if(:identity_store, value(context, :history_store))
      |> put_if(:capability, capability)
      |> put_if(:capability_opts, capability_opts)

    with {:ok, device} <- non_empty(device, :missing_device),
         :ok <- validate_identifier(:capability, capability),
         :ok <- validate_identifier(:field, field),
         :ok <- validate_operator(operator),
         :ok <- validate_expected(expected),
         {:ok, max_age_seconds} <- validate_max_age(max_age_seconds),
         {:ok, entity} <- Zaik.Home.World.get(device, world_opts),
         {:ok, capability_module} <-
           Zaik.Home.Capabilities.Registry.fetch(capability, capability_opts),
         {:ok, field_type} <- capability_field_type(capability_module, field),
         :ok <- validate_comparison(field_type, operator, expected) do
      attrs = %{
        entity_id: entity.id,
        device: entity.name,
        capability: capability,
        field: field,
        operator: operator,
        expected: expected,
        max_age_seconds: max_age_seconds
      }

      {:ok, struct!(__MODULE__, Map.put(attrs, :id, condition_id(attrs)))}
    end
  end

  def preflight(_condition, _context, _opts), do: {:error, :condition_must_be_an_object}

  def evaluate(%__MODULE__{} = condition, context \\ %{}, opts \\ []) do
    capability_opts =
      Keyword.get(opts, :capability_opts) || value(context, :capability_opts) || []

    world_opts =
      []
      |> put_if(:device_store, value(context, :device_store))
      |> put_if(:identity_store, value(context, :history_store))
      |> put_if(:capability, condition.capability)
      |> put_if(:capability_opts, capability_opts)
      |> put_if(:clock, value(context, :clock))

    with {:ok, entity} <- Zaik.Home.World.get(condition.entity_id, world_opts),
         {:ok, observed_at} <- fresh_observation(entity.observed_at, condition, context),
         {:ok, state} <- capability_state(entity, condition.capability),
         {:ok, observed} <- state_field(state, condition.field),
         {:ok, matched} <- compare(condition.operator, observed, condition.expected) do
      {:ok,
       %{
         condition_id: condition.id,
         entity_id: entity.id,
         device: entity.name,
         capability: condition.capability,
         field: condition.field,
         operator: condition.operator,
         expected: condition.expected,
         observed: observed,
         observed_at: DateTime.to_iso8601(observed_at),
         matched: matched
       }}
    end
  end

  def public(%__MODULE__{} = condition), do: Map.from_struct(condition)

  defp capability_field_type(module, field) do
    schema = module.descriptor() |> Map.get(:state_schema, %{})

    case Map.fetch(schema, field) do
      {:ok, type} -> {:ok, to_string(type)}
      :error -> {:error, {:unknown_capability_state_field, field}}
    end
  end

  defp validate_comparison(field_type, operator, expected) do
    base_type = field_type |> String.split("|") |> hd()

    cond do
      operator in @numeric_operators and base_type != "number" ->
        {:error, {:operator_requires_numeric_field, operator, field_type}}

      base_type == "number" and not is_number(expected) ->
        {:error, {:condition_value_type_mismatch, "number"}}

      base_type == "boolean" and not is_boolean(expected) ->
        {:error, {:condition_value_type_mismatch, "boolean"}}

      base_type == "string" and not is_binary(expected) ->
        {:error, {:condition_value_type_mismatch, "string"}}

      true ->
        :ok
    end
  end

  defp fresh_observation(nil, _condition, _context), do: {:error, :missing_condition_observation}

  defp fresh_observation(observed_value, condition, context) do
    with {:ok, observed_at} <- parse_datetime(observed_value) do
      now = Zaik.Time.now(value(context, :clock))
      age = max(0, DateTime.diff(now, observed_at, :second))

      if age <= condition.max_age_seconds do
        {:ok, observed_at}
      else
        {:error,
         {:stale_condition_observation,
          %{
            condition_id: condition.id,
            age_seconds: age,
            maximum_seconds: condition.max_age_seconds
          }}}
      end
    end
  end

  defp capability_state(entity, capability) do
    case Map.fetch(entity.state, capability) do
      {:ok, state} when is_map(state) -> {:ok, state}
      _ -> {:error, {:missing_condition_capability, capability}}
    end
  end

  defp state_field(state, field) do
    case Map.fetch(state, field) do
      {:ok, nil} ->
        {:error, {:missing_condition_field_value, field}}

      {:ok, observed} ->
        {:ok, observed}

      :error ->
        case Enum.find(state, fn {key, _value} -> to_string(key) == field end) do
          {_key, nil} -> {:error, {:missing_condition_field_value, field}}
          {_key, observed} -> {:ok, observed}
          nil -> {:error, {:missing_condition_field_value, field}}
        end
    end
  end

  defp compare("eq", observed, expected), do: {:ok, observed == expected}
  defp compare("neq", observed, expected), do: {:ok, observed != expected}

  defp compare(operator, observed, expected)
       when operator in @numeric_operators and is_number(observed) and is_number(expected) do
    {:ok,
     case operator do
       "lt" -> observed < expected
       "lte" -> observed <= expected
       "gt" -> observed > expected
       "gte" -> observed >= expected
     end}
  end

  defp compare(operator, _observed, _expected),
    do: {:error, {:invalid_condition_comparison, operator}}

  defp validate_operator(operator) when operator in @operators, do: :ok
  defp validate_operator(operator), do: {:error, {:unsupported_condition_operator, operator}}

  defp validate_expected(value) when is_number(value) or is_boolean(value) or is_binary(value),
    do: :ok

  defp validate_expected(_value), do: {:error, :condition_value_must_be_scalar}

  defp validate_max_age(value)
       when is_integer(value) and value >= 1 and value <= @maximum_max_age_seconds,
       do: {:ok, value}

  defp validate_max_age(value), do: {:error, {:invalid_condition_max_age_seconds, value}}

  defp validate_identifier(field, ""), do: {:error, {String.to_atom("missing_#{field}"), field}}
  defp validate_identifier(_field, _value), do: :ok

  defp non_empty(nil, error), do: {:error, error}

  defp non_empty(value, error) do
    value = value |> to_string() |> String.trim()
    if value == "", do: {:error, error}, else: {:ok, value}
  end

  defp condition_id(attrs) do
    attrs
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  defp parse_datetime(%DateTime{} = value), do: {:ok, value}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_condition_observed_at}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid_condition_observed_at}
  defp normalize(nil), do: ""
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
end

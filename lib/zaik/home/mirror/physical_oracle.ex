defmodule Zaik.Home.Mirror.PhysicalOracle do
  @moduledoc """
  Independent physical-semantics oracle for mirror assertions.

  This module intentionally does not call capability normalization, action
  verification, executors, or calibration storage. Scenario authors declare raw
  adapter endpoint semantics independently so a self-consistent but physically
  inverted implementation still fails evaluation.
  """

  @default_tolerance 2.0

  def validate(fixture) when is_map(fixture) do
    capability = normalize(value(fixture, :capability))
    kind = normalize(value(fixture, :kind))
    reported_open = value(fixture, :reported_open)
    reported_closed = value(fixture, :reported_closed)
    tolerance = value(fixture, :tolerance) || @default_tolerance

    cond do
      blank?(value(fixture, :device)) ->
        {:error, :missing_physical_oracle_device}

      blank?(value(fixture, :source)) ->
        {:error, :missing_physical_oracle_source}

      capability != "cover" ->
        {:error, {:unsupported_physical_oracle_capability, capability}}

      kind != "cover_position_linear" ->
        {:error, {:unsupported_physical_oracle_kind, kind}}

      not number?(reported_open) or not number?(reported_closed) ->
        {:error, :invalid_physical_oracle_endpoints}

      reported_open == reported_closed ->
        {:error, :degenerate_physical_oracle_endpoints}

      not number?(tolerance) or tolerance < 0 or tolerance > 20 ->
        {:error, :invalid_physical_oracle_tolerance}

      true ->
        :ok
    end
  end

  def validate(_fixture), do: {:error, :invalid_physical_oracle}

  def evaluate(fixture, target, payload)
      when is_map(fixture) and is_map(target) and is_map(payload) do
    with :ok <- validate(fixture),
         {:ok, expected} <- target_position(target),
         {:ok, reported} <- numeric(value(payload, :position)) do
      actual =
        canonical_position(
          reported,
          value(fixture, :reported_open),
          value(fixture, :reported_closed)
        )

      tolerance = value(fixture, :tolerance) || @default_tolerance

      {:ok,
       %{
         passed?: abs(expected - actual) <= tolerance,
         expected_canonical_position: expected,
         actual_canonical_position: actual,
         reported_position: reported,
         tolerance: tolerance,
         oracle_kind: "cover_position_linear",
         oracle_source: value(fixture, :source)
       }}
    end
  end

  def evaluate(_fixture, _target, _payload), do: {:error, :invalid_physical_oracle_input}

  defp target_position(target) do
    cond do
      not is_nil(value(target, :position)) -> numeric(value(target, :position))
      normalize(value(target, :state)) == "open" -> {:ok, 0.0}
      normalize(value(target, :state)) == "close" -> {:ok, 100.0}
      true -> {:error, :unsupported_physical_oracle_target}
    end
  end

  defp canonical_position(reported, reported_open, reported_closed) do
    position = (reported - reported_open) / (reported_closed - reported_open) * 100
    if abs(position) < 1.0e-12, do: 0.0, else: position
  end

  defp numeric(value) when is_integer(value), do: {:ok, value * 1.0}
  defp numeric(value) when is_float(value), do: {:ok, value}
  defp numeric(_value), do: {:error, :missing_physical_oracle_position}

  defp number?(value), do: is_integer(value) or is_float(value)
  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
  defp normalize(nil), do: ""
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

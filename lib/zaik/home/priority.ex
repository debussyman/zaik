defmodule Zaik.Home.Priority do
  @moduledoc """
  Canonical household priority classes. Numeric weights are deterministic
  ordering values, not model-selected authority.
  """

  @classes [
    safety_security: 100,
    explicit_user: 90,
    privacy_sleep: 80,
    comfort: 60,
    daylight_energy: 40
  ]

  def classes, do: @classes

  def normalize(value) when is_atom(value), do: normalize(Atom.to_string(value))

  def normalize(value) when is_binary(value) do
    normalized =
      value |> String.trim() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")

    case Enum.find(@classes, fn {name, _weight} -> Atom.to_string(name) == normalized end) do
      {name, _weight} -> {:ok, name}
      nil -> {:error, {:unknown_priority_class, value}}
    end
  end

  def normalize(value), do: {:error, {:unknown_priority_class, value}}

  def weight(value) do
    with {:ok, class} <- normalize(value), do: {:ok, Keyword.fetch!(@classes, class)}
  end

  def validate(class, priority) do
    with {:ok, normalized} <- normalize(class),
         {:ok, expected} <- weight(normalized) do
      if priority == expected,
        do: {:ok, {normalized, expected}},
        else: {:error, {:priority_class_mismatch, normalized, expected, priority}}
    end
  end
end

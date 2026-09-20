defmodule Zaik.Home.Query do
  @moduledoc """
  Normalizes model-authored home lookup phrases to stable entity/area terms.

  Tool arguments often repeat the requested capability or time window. Those
  words describe what to read, not which entity to match.
  """

  @version 1

  @lookup_noise MapSet.new(~w(
                  a ago an are at battery batteries blind blinds can celsius change changed changes
                  changing closed cooler cooling cover covers current currently day days degree
                  degrees device devices do does fahrenheit for from fully get getting give historical
                  eight eleven five four history hour hours how humidity humidities illuminance in is
                  last latest linkquality me minute minutes month months nine now of one open opened over
                  partially past
                  please position positions presence reading readings recent recently second seconds
                  sensor sensors seven shade shades show six state status tell temp temperature
                  temperatures ten the three today tonight trend trending twelve two value values warm
                  warmer warming week weeks were what where which window windows yesterday you
                ))

  def version, do: @version

  def entity_lookup(query) when is_binary(query) do
    meaningful =
      query
      |> String.downcase()
      |> String.replace(~r/['’]s\b/, "")
      |> String.replace(~r/['’]/, " ")
      |> String.replace(~r/[^a-z0-9:_-]+/, " ")
      |> String.split(" ", trim: true)
      |> Enum.reject(&(MapSet.member?(@lookup_noise, &1) or numeric?(&1)))
      |> Enum.join(" ")

    if meaningful == "", do: nil, else: meaningful
  end

  def entity_lookup(_query), do: nil

  defp numeric?(token) do
    case Float.parse(token) do
      {_number, ""} -> true
      _ -> false
    end
  end
end

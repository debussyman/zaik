defmodule Zaik.Home.EntityResolverTest do
  use ExUnit.Case, async: true

  alias Zaik.Home.EntityResolver

  @entities [
    %{
      id: "0xleft",
      name: "Lily's bedroom left blind",
      area_id: "lily_bedroom",
      aliases: ["left nursery shade"]
    },
    %{
      id: "0xright",
      name: "Lily's bedroom right blind",
      area_id: "lily_bedroom",
      aliases: []
    },
    %{
      id: "0xsensor",
      name: "Lily's room multi-sensor",
      area_id: "lily_bedroom",
      aliases: ["nursery climate"]
    },
    %{id: "0xmain", name: "Main bedroom sensor", area_id: "main_bedroom", aliases: []}
  ]

  test "capability, plural, time-window, and question words preserve the entity set" do
    variants = [
      "lily bedroom",
      "temperature lily bedroom",
      "temperatures from lily bedroom sensors",
      "temperature readings for lily bedroom over the last 2 hours",
      "what were the temperatures in lily bedroom over the past two hours?",
      "please show current temperature values for lily bedroom"
    ]

    resolved_sets =
      Enum.map(variants, fn query ->
        @entities
        |> EntityResolver.select(query)
        |> Enum.map(& &1.id)
      end)

    assert Enum.uniq(resolved_sets) == [["0xleft", "0xright", "0xsensor"]]
  end

  test "canonical IDs, aliases, partial names, and areas share deterministic matching" do
    assert {:ok, %{id: "0xright"}} = EntityResolver.one(@entities, "0xright")
    assert {:ok, %{id: "0xleft"}} = EntityResolver.one(@entities, "left nursery shade")
    assert {:ok, %{id: "0xsensor"}} = EntityResolver.one(@entities, "nursery climate")

    assert {:error, {:ambiguous, names}} = EntityResolver.one(@entities, "lily bedroom")

    assert names == [
             "Lily's bedroom left blind",
             "Lily's bedroom right blind",
             "Lily's room multi-sensor"
           ]

    assert {:ok, %{id: "sensor"}} =
             EntityResolver.one(
               [%{id: "sensor", name: "Room sensor", area_id: "room", aliases: []}],
               "sensor"
             )

    assert EntityResolver.select(@entities, "what is the temperature?") == []
  end
end

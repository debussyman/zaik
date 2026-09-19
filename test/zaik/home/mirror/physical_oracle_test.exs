defmodule Zaik.Home.Mirror.PhysicalOracleTest do
  use ExUnit.Case, async: true

  alias Zaik.Home.Mirror.PhysicalOracle

  test "evaluates raw reports from independently declared endpoint semantics" do
    fixture = %{
      device: "cover",
      capability: "cover",
      kind: "cover_position_linear",
      source: "independent installation fixture",
      reported_open: 100,
      reported_closed: 0,
      tolerance: 1
    }

    assert {:ok,
            %{
              passed?: true,
              expected_canonical_position: 100.0,
              actual_canonical_position: 100.0,
              reported_position: reported
            }} = PhysicalOracle.evaluate(fixture, %{"position" => 100}, %{"position" => 0})

    assert_in_delta reported, 0.0, 1.0e-12

    assert {:ok, %{passed?: false, actual_canonical_position: actual}} =
             PhysicalOracle.evaluate(fixture, %{"position" => 100}, %{"position" => 100})

    assert_in_delta actual, 0.0, 1.0e-12
  end

  test "rejects ambiguous or unsupported physical fixtures" do
    assert {:error, :degenerate_physical_oracle_endpoints} =
             PhysicalOracle.validate(%{
               device: "cover",
               capability: "cover",
               kind: "cover_position_linear",
               source: "independent installation fixture",
               reported_open: 50,
               reported_closed: 50
             })

    assert {:error, {:unsupported_physical_oracle_capability, "temperature"}} =
             PhysicalOracle.validate(%{
               device: "sensor",
               capability: "temperature",
               kind: "cover_position_linear",
               source: "independent installation fixture",
               reported_open: 0,
               reported_closed: 100
             })
  end
end

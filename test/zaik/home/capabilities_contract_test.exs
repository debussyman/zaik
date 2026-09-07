defmodule Zaik.Home.CapabilitiesContractTest do
  use ExUnit.Case, async: true

  test "cover endpoint state is derived from canonical position despite adapter direction labels" do
    assert %{position: 0, state: "CLOSE", adapter_state: "OPEN"} =
             Zaik.Home.Capabilities.Cover.state(%{
               payload: %{"position" => 0, "state" => "OPEN"}
             })

    assert %{position: 100, state: "OPEN", adapter_state: "CLOSE"} =
             Zaik.Home.Capabilities.Cover.state(%{
               payload: %{"position" => 100, "state" => "CLOSE"}
             })
  end

  test "every configured capability passes the baseline composability contract" do
    assert :ok = Zaik.Home.Capabilities.Registry.validate()

    Enum.each(Zaik.Home.Capabilities.Registry.modules(), fn module ->
      assert :ok = Zaik.Home.Capabilities.Contract.validate(module)
    end)
  end
end

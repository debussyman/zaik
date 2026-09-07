defmodule Zaik.Home.CapabilitiesContractTest do
  use ExUnit.Case, async: true

  test "every configured capability passes the baseline composability contract" do
    assert :ok = Zaik.Home.Capabilities.Registry.validate()

    Enum.each(Zaik.Home.Capabilities.Registry.modules(), fn module ->
      assert :ok = Zaik.Home.Capabilities.Contract.validate(module)
    end)
  end
end

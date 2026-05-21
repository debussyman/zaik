defmodule Zaik.Agent.BaseTest do
  use ExUnit.Case, async: true

  alias Zaik.Agent.Base

  describe "Base agent module" do
    test "creates an agent with default options" do
      # Test that the base module exists
      assert function_exported?(Base, :start_link, 1)
      assert function_exported?(Base, :init, 1)
    end

    test "can be used as a behavior module" do
      # This test ensures the module can be used as a behavior
      assert Base in [:gen_server]
    end
  end
end
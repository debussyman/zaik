defmodule Zaik.Agent.HelloWorldTest do
  use ExUnit.Case, async: true

  describe "HelloWorld agent" do
    test "greets with its configured name" do
      name = unique_name()
      start_supervised!({Zaik.Agent.HelloWorld, name: name, agent_name: "TestAgent"})

      assert Zaik.Agent.HelloWorld.hello(name) == "Hello from TestAgent!"
    end

    test "stores messages in state" do
      name = unique_name()
      start_supervised!({Zaik.Agent.HelloWorld, name: name})

      assert :ok = Zaik.Agent.HelloWorld.send_message(name, "Hello test")
      assert eventually(fn -> Zaik.Agent.HelloWorld.state(name).messages == ["Hello test"] end)
    end
  end

  defp unique_name do
    String.to_atom("hello_world_#{System.unique_integer([:positive])}")
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end
end

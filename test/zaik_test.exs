defmodule ZaikTest do
  use ExUnit.Case, async: false

  describe "public API" do
    test "hello delegates to the supervised hello world agent" do
      assert Zaik.hello() == "Hello from HelloWorldAgent!"
    end

    test "send_message delegates to the supervised hello world agent" do
      assert :ok = Zaik.send_message("Test message")

      assert %{messages: ["Test message" | _], last_seen: %DateTime{}} =
               Zaik.Agent.HelloWorld.state()
    end
  end
end

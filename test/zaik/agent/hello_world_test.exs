defmodule Zaik.Agent.HelloWorldTest do
  use ExUnit.Case, async: true

  describe "HelloWorld agent" do
    test "greets with a default message" do
      # Test that the agent starts with a default greeting
      {:ok, agent_pid} = Zaik.Agent.HelloWorld.start_link([])
      assert Process.alive?(agent_pid)
    end

    test "sends a message" do
      # Test the send_message function
      assert :ok == Zaik.send_message("Hello test")
    end
  end
end
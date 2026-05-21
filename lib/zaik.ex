defmodule Zaik do
  @moduledoc """
  Zaik is a personal AI agent runtime inspired by OpenClaw, built with Elixir's actor system.

  The system is designed to run multiple AI agents that can:
  - Process messages 
  - Handle periodic ticks
  - Store state
  - Communicate with each other
  """

  @doc """
  Start the Zaik system with all required supervisors and agents.
  """
  def start do
    Application.start(:zaik)
  end

  @doc """
  Stop the Zaik system.
  """
  def stop do
    Application.stop(:zaik)
  end

  @doc """
  Get a greeting from the hello world agent.
  """
  def hello do
    Zaik.Agent.HelloWorld.hello()
  end

  @doc """
  Send a message to the hello world agent.
  """
  def send_message(message) do
    Zaik.Agent.HelloWorld.send_message(message)
  end
end

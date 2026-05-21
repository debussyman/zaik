defmodule Zaik.Application do
  @moduledoc """
  The Zaik Application.

  This module defines the application structure and supervision tree for the Zaik system.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the clock service that provides periodic ticks
      Zaik.Clock,

      # Start the hello world agent
      Zaik.Agent.HelloWorld
    ]

    opts = [strategy: :one_for_one, name: Zaik.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
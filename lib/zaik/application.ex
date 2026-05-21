defmodule Zaik.Application do
  @moduledoc """
  The Zaik Application.

  This module defines the root supervision tree for the Zaik system.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Zaik.Clock,
      Zaik.Agent.Supervisor
    ]

    opts = [strategy: :one_for_one, name: Zaik.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

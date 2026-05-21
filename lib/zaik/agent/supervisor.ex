defmodule Zaik.Agent.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  def init(_opts) do
    children = [
      # Add your agent workers here
      # For now, we'll include a basic hello world agent
      %{
        id: Zaik.Agent.HelloWorld,
        start: {Zaik.Agent.HelloWorld, :start_link, []}
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
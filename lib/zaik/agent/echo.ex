defmodule Zaik.Agent.Echo do
  @moduledoc """
  Echo task agent for testing.
  """

  use Zaik.Agent.TaskRunner

  @impl true
  def run_task(task, state) do
    {:ok, task.payload, state}
  end
end

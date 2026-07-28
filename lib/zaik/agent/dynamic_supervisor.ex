defmodule Zaik.Agent.DynamicSupervisor do
  @moduledoc """
  Dynamic supervisor for task agents.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_task_agent(%Zaik.Task{} = task, agent_module, dispatcher \\ Zaik.Dispatcher) do
    child_spec = spec(task, agent_module, dispatcher)
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  def stop_agent(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp spec(%Zaik.Task{} = task, agent_module, dispatcher) do
    child_spec = %{
      id: {agent_module, task.id},
      start:
        {agent_module, :start_link,
         [[task: task, dispatcher: dispatcher, name: via_name(task.id)]]},
      restart: :temporary,
      type: :worker
    }

    child_spec
  end

  defp via_name(task_id) do
    {:via, Registry, {Zaik.Agent.Registry, {:task_agent, task_id}}}
  end
end

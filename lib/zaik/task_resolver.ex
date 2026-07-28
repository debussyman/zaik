defmodule Zaik.TaskResolver do
  @moduledoc """
  Resolves task types to agent modules.
  """

  @resolutions %{
    echo: Zaik.Agent.Echo
  }

  @doc """
  Resolve a task type to an agent module.
  """
  @spec resolve(Zaik.Task.t() | atom()) :: {:ok, module()} | {:error, :unknown_task_type}
  def resolve(%Zaik.Task{type: type}), do: resolve(type)

  def resolve(task_type) when is_atom(task_type) do
    case Map.get(@resolutions, task_type) do
      nil -> {:error, :unknown_task_type}
      module -> {:ok, module}
    end
  end

  def resolve(_), do: {:error, :unknown_task_type}
end

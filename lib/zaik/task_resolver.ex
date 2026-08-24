defmodule Zaik.TaskResolver do
  @moduledoc """
  Resolves task types to agent modules.
  """

  @default_task_modules %{
    echo: Zaik.Agent.Echo,
    system_status: Zaik.Agent.SystemStatus,
    llm_prompt: Zaik.Agent.LLM
  }

  @doc """
  Built-in task type mappings.
  """
  @spec default_task_modules() :: %{atom() => module()}
  def default_task_modules, do: @default_task_modules

  @doc """
  Effective task type mappings.

  Built-in defaults are merged with `config :zaik, :task_modules`. Configured
  task modules can add new task types or override defaults.
  """
  @spec task_modules() :: %{atom() => module()}
  def task_modules do
    Map.merge(@default_task_modules, configured_task_modules())
  end

  @doc """
  Resolve a task type to an agent module.
  """
  @spec resolve(Zaik.Task.t() | atom()) :: {:ok, module()} | {:error, :unknown_task_type}
  def resolve(%Zaik.Task{type: type}), do: resolve(type)

  def resolve(task_type) when is_atom(task_type) do
    case Map.fetch(task_modules(), task_type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_task_type}
    end
  end

  def resolve(_), do: {:error, :unknown_task_type}

  defp configured_task_modules do
    :zaik
    |> Application.get_env(:task_modules, [])
    |> normalize_task_modules()
  end

  defp normalize_task_modules(task_modules) when is_map(task_modules) do
    task_modules
    |> Enum.reduce(%{}, &put_valid_task_module/2)
  end

  defp normalize_task_modules(task_modules) when is_list(task_modules) do
    Enum.reduce(task_modules, %{}, &put_valid_task_module/2)
  end

  defp normalize_task_modules(_task_modules), do: %{}

  defp put_valid_task_module({task_type, module}, acc)
       when is_atom(task_type) and is_atom(module) do
    Map.put(acc, task_type, module)
  end

  defp put_valid_task_module(_entry, acc), do: acc
end

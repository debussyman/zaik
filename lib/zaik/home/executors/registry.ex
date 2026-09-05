defmodule Zaik.Home.Executors.Registry do
  @moduledoc """
  Runtime-discovered registry of capability executors.

  It performs lookups on every call so newly compiled or reconfigured executor
  modules can participate without restarting an AgentChat process.
  """

  @default_modules [Zaik.Home.Executors.Cover]

  def modules(opts \\ []) do
    configured = Application.get_env(:zaik, :home_executors, [])

    base =
      Keyword.get(opts, :modules) ||
        Keyword.get(configured, :modules, @default_modules)

    additional =
      Keyword.get(opts, :additional_modules) ||
        Keyword.get(configured, :additional_modules, [])

    (List.wrap(base) ++ List.wrap(additional)) |> Enum.uniq()
  end

  def fetch(capability, opts \\ []) do
    capability = normalize(capability)

    Enum.find_value(modules(opts), {:error, {:unsupported_capability, capability}}, fn module ->
      if valid_module?(module) and normalize(module.capability()) == capability do
        {:ok, module}
      end
    end)
  end

  def execute(capability, entity, target, context \\ %{}, opts \\ []) do
    with {:ok, module} <- fetch(capability, opts) do
      module.execute(entity, target, context)
    end
  rescue
    error -> {:error, {:executor_exception, capability, error}}
  catch
    :exit, reason -> {:error, {:executor_exit, capability, reason}}
  end

  def validate(opts \\ []) do
    invalid = Enum.reject(modules(opts), &valid_module?/1)

    capabilities =
      modules(opts) |> Enum.filter(&valid_module?/1) |> Enum.map(&normalize(&1.capability()))

    duplicates = capabilities -- Enum.uniq(capabilities)

    cond do
      invalid != [] -> {:error, {:invalid_executor_modules, invalid}}
      duplicates != [] -> {:error, {:duplicate_executors, Enum.uniq(duplicates)}}
      true -> :ok
    end
  end

  defp valid_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :capability, 0) and
      function_exported?(module, :execute, 3)
  end

  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
end

defmodule Zaik.Home.Capabilities.Registry do
  @moduledoc """
  Runtime-discovered home capability registry.

  Like the tool registry, it intentionally avoids caching modules so hot code
  reloads and runtime configuration changes are visible on the next snapshot.
  """

  @default_modules [
    Zaik.Home.Capabilities.Temperature,
    Zaik.Home.Capabilities.Humidity,
    Zaik.Home.Capabilities.Illuminance,
    Zaik.Home.Capabilities.Presence,
    Zaik.Home.Capabilities.Cover,
    Zaik.Home.Capabilities.Battery,
    Zaik.Home.Capabilities.LinkQuality
  ]

  def modules(opts \\ []) do
    configured = Application.get_env(:zaik, :home_capabilities, [])

    base =
      Keyword.get(opts, :modules) ||
        Keyword.get(configured, :modules, @default_modules)

    additional =
      Keyword.get(opts, :additional_modules) ||
        Keyword.get(configured, :additional_modules, [])

    (List.wrap(base) ++ List.wrap(additional)) |> Enum.uniq()
  end

  def detected(device, opts \\ []) when is_map(device) do
    modules(opts)
    |> Enum.flat_map(fn module ->
      if valid_module?(module) and module.detected?(device) do
        descriptor = module.descriptor()
        [%{module: module, descriptor: descriptor, state: module.state(device)}]
      else
        []
      end
    end)
    |> Enum.sort_by(& &1.descriptor.id)
  end

  def fetch(id, opts \\ []) do
    id = normalize(id)

    Enum.find_value(modules(opts), {:error, {:unknown_capability, id}}, fn module ->
      if valid_module?(module) and normalize(module.descriptor().id) == id do
        {:ok, module}
      end
    end)
  end

  def fingerprint(opts \\ []) do
    opts
    |> modules()
    |> Enum.filter(&valid_module?/1)
    |> Enum.map(& &1.descriptor())
    |> Enum.sort_by(& &1.id)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def validate(opts \\ []) do
    modules = modules(opts)

    contract_errors =
      Enum.flat_map(modules, fn module ->
        case Zaik.Home.Capabilities.Contract.validate(module) do
          :ok -> []
          {:error, reason} -> [{module, reason}]
        end
      end)

    descriptors =
      modules
      |> Enum.filter(&valid_module?/1)
      |> Enum.map(& &1.descriptor())

    ids = Enum.map(descriptors, &normalize(&1.id))
    duplicates = ids -- Enum.uniq(ids)

    cond do
      contract_errors != [] -> {:error, {:capability_contract_errors, contract_errors}}
      duplicates != [] -> {:error, {:duplicate_capability_ids, Enum.uniq(duplicates)}}
      true -> :ok
    end
  end

  defp valid_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :descriptor, 0) and
      function_exported?(module, :detected?, 1) and function_exported?(module, :state, 1) and
      function_exported?(module, :validate_target, 1)
  end

  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
end

defmodule Zaik.Home.Policies.Registry do
  @moduledoc """
  Uncached runtime registry for home policy modules.
  """

  @default_modules [Zaik.Home.Policies.DaylightHarvesting]
  @modes [:off, :shadow, :advisory, :canary, :active]

  def modules(opts \\ []) do
    configured = Application.get_env(:zaik, :home_policies, [])

    base = Keyword.get(opts, :modules) || Keyword.get(configured, :modules, @default_modules)

    additional =
      Keyword.get(opts, :additional_modules) || Keyword.get(configured, :additional_modules, [])

    (List.wrap(base) ++ List.wrap(additional)) |> Enum.uniq()
  end

  def descriptors(opts \\ []) do
    opts
    |> modules()
    |> Enum.flat_map(fn module ->
      case descriptor(module) do
        {:ok, descriptor} -> [descriptor]
        {:error, _reason} -> []
      end
    end)
    |> Enum.sort_by(& &1.id)
  end

  def fetch(id, opts \\ []) do
    id = normalize(id)

    Enum.find_value(modules(opts), {:error, {:unknown_policy, id}}, fn module ->
      case descriptor(module) do
        {:ok, %{id: ^id} = descriptor} -> {:ok, %{module: module, descriptor: descriptor}}
        _ -> nil
      end
    end)
  end

  def evaluate(id, context, opts \\ []) when is_map(context) do
    with {:ok, %{module: module}} <- fetch(id, opts) do
      module.evaluate(context, opts)
    end
  end

  def validate(opts \\ []) do
    results = Enum.map(modules(opts), &descriptor/1)
    errors = for {:error, error} <- results, do: error
    ids = for {:ok, descriptor} <- results, do: descriptor.id
    duplicates = ids -- Enum.uniq(ids)

    cond do
      errors != [] -> {:error, {:policy_contract_errors, errors}}
      duplicates != [] -> {:error, {:duplicate_policy_ids, Enum.uniq(duplicates)}}
      true -> :ok
    end
  end

  def fingerprint(opts \\ []) do
    opts
    |> descriptors()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def descriptor(module) when is_atom(module) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :descriptor, 0),
         true <- function_exported?(module, :evaluate, 2),
         descriptor when is_map(descriptor) <- module.descriptor(),
         {:ok, descriptor} <- normalize_descriptor(descriptor) do
      {:ok, descriptor}
    else
      false -> {:error, {:invalid_policy_module, module}}
      other -> {:error, {:invalid_policy_descriptor, module, other}}
    end
  rescue
    error -> {:error, {:policy_descriptor_exception, module, error}}
  end

  defp normalize_descriptor(descriptor) do
    id = normalize(value(descriptor, :id))
    version = value(descriptor, :version)
    description = value(descriptor, :description)
    priority = value(descriptor, :priority)
    dependencies = List.wrap(value(descriptor, :dependencies)) |> Enum.map(&normalize/1)
    mode = value(descriptor, :default_mode)

    if id != "" and is_binary(version) and version != "" and is_binary(description) and
         description != "" and is_integer(priority) and priority in 0..100 and
         dependencies != [] and Enum.all?(dependencies, &(&1 != "")) and mode in @modes do
      {:ok,
       %{
         id: id,
         version: version,
         description: description,
         priority: priority,
         dependencies: dependencies,
         default_mode: mode
       }}
    else
      {:error, :invalid_descriptor}
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp normalize(nil), do: ""
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
end

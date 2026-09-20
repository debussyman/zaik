defmodule Zaik.Tools.Registry do
  @moduledoc """
  Runtime-discovered registry for agent tools.

  The registry deliberately keeps no descriptor or module cache. Tool modules
  can be recompiled and the configured module list can be changed at runtime;
  the next lookup observes the new code.
  """

  @default_modules [
    Zaik.Tools.SQLQuery,
    Zaik.Home.Tools.ListDevices,
    Zaik.Home.Tools.GetState,
    Zaik.Home.Tools.GetHistory,
    Zaik.Home.Tools.GetAreaContext,
    Zaik.Home.Tools.GetGoalContext,
    Zaik.Home.Tools.GetModes,
    Zaik.Home.Tools.GetActionStatus,
    Zaik.Home.Tools.RetryAction,
    Zaik.Home.Tools.ActivateMode,
    Zaik.Home.Tools.CancelMode,
    Zaik.Home.Tools.ExecutePlan,
    Zaik.Home.Tools.ApplyDevicePreset,
    Zaik.Home.Tools.CaptureDevicePreset,
    Zaik.Home.Tools.ControlDevice,
    Zaik.Home.Tools.ControlBlind,
    Zaik.Tools.ProposeHomeSkill
  ]

  def modules(opts \\ []) do
    configured = Application.get_env(:zaik, :tools, [])

    base =
      Keyword.get(opts, :modules) ||
        Keyword.get(configured, :modules, @default_modules)

    additional =
      Keyword.get(opts, :additional_modules) ||
        Keyword.get(configured, :additional_modules, [])

    (List.wrap(base) ++ List.wrap(additional))
    |> Enum.uniq()
  end

  def descriptors(opts \\ []) do
    opts
    |> modules()
    |> Enum.map(&descriptor/1)
    |> Enum.flat_map(fn
      {:ok, descriptor} -> [descriptor]
      {:error, _reason} -> []
    end)
  end

  def fingerprint(opts \\ []) do
    opts
    |> descriptors()
    |> Enum.sort_by(& &1.name)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def validate(opts \\ []) do
    results = Enum.map(modules(opts), &descriptor/1)
    errors = for {:error, error} <- results, do: error

    names = for {:ok, descriptor} <- results, do: descriptor.name
    duplicates = names -- Enum.uniq(names)

    cond do
      errors != [] -> {:error, errors}
      duplicates != [] -> {:error, {:duplicate_tool_names, Enum.uniq(duplicates)}}
      true -> :ok
    end
  end

  def fetch(name, opts \\ []) do
    normalized = normalize_name(name)

    Enum.find_value(modules(opts), {:error, {:unknown_tool, name}}, fn module ->
      with {:ok, descriptor} <- descriptor(module),
           true <- normalized in [descriptor.name | descriptor.aliases] do
        {:ok, %{module: module, descriptor: descriptor}}
      else
        _ -> nil
      end
    end)
  end

  def run(name, args, context \\ %{}, opts \\ [])

  def run(name, args, context, opts) when is_map(args) and is_map(context) do
    with {:ok, %{module: module}} <- fetch(name, opts) do
      module.run(args, context)
    end
  rescue
    error -> {:error, {:tool_exception, name, error}}
  catch
    :exit, reason -> {:error, {:tool_exit, name, reason}}
  end

  def run(name, _args, _context, _opts), do: {:error, {:invalid_tool_args, name}}

  def descriptor(module) when is_atom(module) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :descriptor, 0),
         true <- function_exported?(module, :run, 2),
         descriptor when is_map(descriptor) <- module.descriptor(),
         {:ok, descriptor} <- normalize_descriptor(descriptor) do
      {:ok, descriptor}
    else
      false -> {:error, {:invalid_tool_module, module}}
      other -> {:error, {:invalid_tool_descriptor, module, other}}
    end
  rescue
    error -> {:error, {:tool_descriptor_exception, module, error}}
  end

  defp normalize_descriptor(descriptor) do
    name = value(descriptor, :name)
    description = value(descriptor, :description)
    input_schema = value(descriptor, :input_schema)
    kind = value(descriptor, :kind)
    risk = value(descriptor, :risk)
    aliases = List.wrap(value(descriptor, :aliases) || [])

    if is_binary(name) and String.trim(name) != "" and is_binary(description) and
         is_map(input_schema) and kind in [:read, :action] and
         risk in [:none, :low, :medium, :high] do
      {:ok,
       %{
         name: normalize_name(name),
         aliases: Enum.map(aliases, &normalize_name/1),
         description: description,
         input_schema: input_schema,
         kind: kind,
         risk: risk
       }}
    else
      {:error, :invalid_descriptor}
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end
end

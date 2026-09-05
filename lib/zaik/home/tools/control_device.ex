defmodule Zaik.Home.Tools.ControlDevice do
  @moduledoc """
  Capability-based home control tool.

  The model names an entity, capability, and semantic target. Elixir resolves
  the entity, validates the target through the capability contract, and invokes
  the registered executor. No adapter topic or wire payload is accepted from
  the model.
  """

  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "control_device",
      aliases: ["set_home_target"],
      description: "Request a validated low-risk capability target for a known home entity.",
      kind: :action,
      risk: :low,
      input_schema: %{
        "type" => "object",
        "required" => ["device", "capability", "target"],
        "properties" => %{
          "device" => %{"type" => "string"},
          "capability" => %{"type" => "string"},
          "target" => %{"type" => "object"}
        }
      }
    }
  end

  @impl true
  def run(args, context) do
    device = value(args, :device) || value(args, :entity_id)
    capability = value(args, :capability)
    target = value(args, :target)

    world_opts =
      []
      |> put_if(:device_store, value(context, :device_store))
      |> put_if(:capability, capability)
      |> put_if(:capability_opts, value(context, :capability_opts))

    executor_opts = value(context, :executor_opts) || []

    with {:ok, device} <- non_empty(device, :missing_device),
         {:ok, capability} <- non_empty(capability, :missing_capability),
         {:ok, target} <- target_map(target),
         {:ok, entity} <- Zaik.Home.World.get(device, world_opts),
         {:ok, capability_module} <- Zaik.Home.Capabilities.Registry.fetch(capability),
         {:ok, normalized_target} <- capability_module.validate_target(target),
         {:ok, result} <-
           Zaik.Home.Executors.Registry.execute(
             capability,
             entity,
             normalized_target,
             context,
             executor_opts
           ) do
      {:ok, result}
    end
  end

  defp target_map(target) when is_map(target), do: {:ok, target}
  defp target_map(_target), do: {:error, :missing_target}

  defp non_empty(nil, error), do: {:error, error}

  defp non_empty(value, error) do
    value = value |> to_string() |> String.trim()
    if value == "", do: {:error, error}, else: {:ok, value}
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

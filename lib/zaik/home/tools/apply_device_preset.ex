defmodule Zaik.Home.Tools.ApplyDevicePreset do
  @moduledoc "Applies a named generic device-capability preset through normal validated control."

  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "apply_device_preset",
      aliases: ["apply_home_preset"],
      description: "Apply an existing named preset to one known device capability.",
      kind: :action,
      risk: :low,
      input_schema: %{
        "type" => "object",
        "required" => ["device", "capability", "preset"],
        "properties" => %{
          "device" => %{"type" => "string"},
          "capability" => %{"type" => "string"},
          "preset" => %{"type" => "string"}
        }
      }
    }
  end

  @impl true
  def run(args, context) do
    with {:ok, device} <- required(args, :device),
         {:ok, capability} <- required(args, :capability),
         {:ok, preset_name} <- required(args, :preset),
         {:ok, preset} <-
           Zaik.Home.DevicePresetStore.get(
             device,
             preset_name,
             [capability: capability],
             value(context, :preset_store) || Zaik.Home.DevicePresetStore
           ),
         target when is_map(target) <- preset["target"] do
      Zaik.Home.Tools.ControlDevice.run(
        %{"device" => device, "capability" => capability, "target" => target},
        context
      )
    else
      nil -> {:error, :invalid_preset_target}
      {:error, :not_found} -> {:error, {:preset_not_found, value(args, :preset)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp required(args, key) do
    case value(args, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, {:missing, key}}, else: {:ok, value}

      _ ->
        {:error, {:missing, key}}
    end
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end
end

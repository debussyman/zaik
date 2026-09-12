defmodule Zaik.Home.Tools.CaptureDevicePreset do
  @moduledoc "Captures fresh canonical capability state as a named generic preset."

  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "capture_device_preset",
      aliases: ["capture_home_preset"],
      description: "Capture a device's fresh canonical capability state as a named preset.",
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
    clock = value(context, :clock)
    now = Zaik.Time.now(clock)
    maximum_age = value(context, :max_state_age_seconds) || 120

    with {:ok, device} <- required(args, :device),
         {:ok, capability} <- required(args, :capability),
         {:ok, preset} <- required(args, :preset),
         {:ok, entity} <-
           Zaik.Home.World.get(device,
             device_store: value(context, :device_store) || Zaik.Home.DeviceStore,
             identity_store: value(context, :history_store) || Zaik.Home.HistoryStore,
             capability: capability,
             clock: clock
           ),
         :ok <- fresh(entity.observed_at, now, maximum_age),
         {:ok, module} <- Zaik.Home.Capabilities.Registry.fetch(capability),
         true <- function_exported?(module, :capture_target, 1),
         state when is_map(state) <- Map.get(entity.state, capability),
         {:ok, target} <- module.capture_target(state),
         {:ok, stored} <-
           Zaik.Home.DevicePresetStore.put(
             entity.name,
             preset,
             capability,
             target,
             %{
               source: "capture",
               created_by: value(context, :sender_id) || value(context, :created_by),
               metadata: %{
                 entity_id: entity.id,
                 observed_at: entity.observed_at,
                 snapshot_source: entity.source
               }
             },
             value(context, :preset_store) || Zaik.Home.DevicePresetStore
           ) do
      {:ok, stored}
    else
      false -> {:error, {:capture_not_supported, value(args, :capability)}}
      nil -> {:error, :capability_state_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fresh(observed_at, now, maximum_age) do
    case parse_time(observed_at) do
      {:ok, observed} ->
        if DateTime.diff(now, observed, :second) <= maximum_age,
          do: :ok,
          else: {:error, :stale_state}

      _ ->
        {:error, :missing_observed_at}
    end
  end

  defp parse_time(%DateTime{} = value), do: {:ok, value}

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp parse_time(_), do: :error

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

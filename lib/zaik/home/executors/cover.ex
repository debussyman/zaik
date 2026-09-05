defmodule Zaik.Home.Executors.Cover do
  @moduledoc false
  @behaviour Zaik.Home.Executor

  @impl true
  def capability, do: "cover"

  @impl true
  def execute(entity, target, context) do
    opts =
      []
      |> put_if(:device_store, value(context, :device_store))
      |> put_if(:preset_store, value(context, :preset_store))
      |> put_if(:mqtt_client, value(context, :mqtt_client))
      |> put_if(:base_topic, value(context, :base_topic))

    with {:ok, blind_target} <- blind_target(target),
         {:ok, result} <- Zaik.Home.Blinds.control(entity.name, blind_target, opts) do
      {:ok,
       %{
         entity_id: entity.id,
         device: entity.name,
         capability: "cover",
         target: target,
         topic: result.topic,
         payload: result.payload,
         status: "accepted",
         verified: false,
         requested_at: DateTime.to_iso8601(result.requested_at)
       }}
    end
  end

  defp blind_target(%{"position" => position}), do: {:ok, {:position, position}}
  defp blind_target(%{"state" => state}), do: {:ok, {:state, state}}
  defp blind_target(%{"preset" => preset}), do: {:ok, {:preset, preset}}
  defp blind_target(_target), do: {:error, :invalid_cover_target}

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

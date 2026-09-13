defmodule Zaik.Home.Tools.CancelMode do
  @moduledoc "Cancels an exact household-mode lease ID without controlling devices."

  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "cancel_home_mode",
      aliases: [],
      description: "Cancel an exact active bedtime or privacy mode lease ID.",
      kind: :action,
      risk: :low,
      input_schema: %{
        "type" => "object",
        "required" => ["mode_id"],
        "properties" => %{"mode_id" => %{"type" => "string"}}
      }
    }
  end

  @impl true
  def run(args, context) do
    case value(args, :mode_id) do
      id when is_binary(id) and id != "" ->
        Zaik.Home.Autonomy.ModeStore.cancel(
          String.trim(id),
          owner(context),
          [clock: value(context, :clock)],
          value(context, :mode_store) || Zaik.Home.Autonomy.ModeStore
        )

      _ ->
        {:error, :missing_mode_id}
    end
  end

  defp owner(context) do
    (value(context, :sender_id) || value(context, :sender_name) || value(context, :created_by) ||
       "operator")
    |> to_string()
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
end

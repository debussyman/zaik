defmodule Zaik.Home.ControlTool do
  @moduledoc """
  Validated home action tools callable by the house agent.

  The model chooses semantic tools/targets; this module normalizes them and
  delegates to device-specific validators/executors.
  """

  def run(tool, args, context \\ %{})

  def run(tool, args, _context) when tool in ["control_blind", :control_blind] and is_map(args) do
    device =
      Map.get(args, "device") || Map.get(args, :device) || Map.get(args, "device_name") ||
        Map.get(args, :device_name)

    target = Map.get(args, "target") || Map.get(args, :target) || args

    with {:ok, device} <- non_empty(device, :missing_device),
         {:ok, target} <- normalize_blind_target(target),
         {:ok, result} <- Zaik.Home.Blinds.control(device, target) do
      {:ok,
       %{
         tool: "control_blind",
         device: result.device.friendly_name,
         topic: result.topic,
         payload: result.payload,
         status: "accepted",
         verified: false,
         requested_at: DateTime.to_iso8601(result.requested_at)
       }}
    end
  end

  def run(tool, _args, _context), do: {:error, {:unsupported_tool, tool}}

  defp normalize_blind_target(%{"action" => action, "preset" => preset})
       when is_binary(action) and is_binary(preset),
       do: normalize_action_target(action, preset)

  defp normalize_blind_target(%{action: action, preset: preset})
       when is_binary(action) and is_binary(preset),
       do: normalize_action_target(action, preset)

  defp normalize_blind_target(%{"action" => action}) when is_binary(action),
    do: normalize_action_target(action, nil)

  defp normalize_blind_target(%{action: action}) when is_binary(action),
    do: normalize_action_target(action, nil)

  defp normalize_blind_target(%{"position" => position}), do: {:ok, {:position, position}}
  defp normalize_blind_target(%{position: position}), do: {:ok, {:position, position}}

  defp normalize_blind_target(%{"preset" => preset}) when is_binary(preset),
    do: {:ok, {:preset, preset}}

  defp normalize_blind_target(%{preset: preset}) when is_binary(preset),
    do: {:ok, {:preset, preset}}

  defp normalize_blind_target(%{"preset_name" => preset}) when is_binary(preset),
    do: {:ok, {:preset, preset}}

  defp normalize_blind_target(%{preset_name: preset}) when is_binary(preset),
    do: {:ok, {:preset, preset}}

  defp normalize_blind_target(%{"state" => state}) when is_binary(state),
    do: normalize_state_target(state)

  defp normalize_blind_target(%{state: state}) when is_binary(state),
    do: normalize_state_target(state)

  defp normalize_blind_target(target) when is_binary(target),
    do: Zaik.Home.Blinds.target_from_text(target)

  defp normalize_blind_target(_target), do: {:error, :missing_target}

  defp normalize_action_target(action, preset) do
    case action |> to_string() |> String.trim() |> String.downcase() do
      value when value in ["set_preset", "preset", "apply_preset"] and is_binary(preset) ->
        {:ok, {:preset, preset}}

      value when value in ["close", "closed", "down"] ->
        {:ok, {:state, "CLOSE"}}

      value when value in ["open", "opened", "up"] ->
        {:ok, {:state, "OPEN"}}

      value when value in ["stop", "halt"] ->
        {:ok, {:state, "STOP"}}

      _ ->
        {:error, :invalid_target}
    end
  end

  defp normalize_state_target(state) do
    case String.upcase(String.trim(state)) do
      state when state in ["OPEN", "CLOSE", "STOP"] -> {:ok, {:state, state}}
      "CLOSED" -> {:ok, {:state, "CLOSE"}}
      other -> Zaik.Home.Blinds.target_from_text(other)
    end
  end

  defp non_empty(nil, error), do: {:error, error}

  defp non_empty(value, error) do
    value = value |> to_string() |> String.trim()
    if value == "", do: {:error, error}, else: {:ok, value}
  end
end

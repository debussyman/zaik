defmodule Zaik.Home.Executors.Cover do
  @moduledoc false
  @behaviour Zaik.Home.Executor

  @impl true
  def capability, do: "cover"

  @impl true
  def prepare(entity, %{"preset" => preset_name}, context) do
    store = value(context, :preset_store) || Zaik.Home.DevicePresetStore

    with {:ok, preset} <-
           Zaik.Home.DevicePresetStore.get(
             entity.name,
             preset_name,
             [capability: "cover"],
             store
           ),
         target when is_map(target) <- preset["target"],
         {:ok, normalized_target} <- Zaik.Home.Capabilities.Cover.validate_target(target) do
      {:ok, normalized_target}
    else
      {:error, :not_found} -> {:error, {:preset_not_found, preset_name}}
      nil -> {:error, {:preset_not_found, preset_name}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:invalid_preset_target, preset_name}}
    end
  end

  def prepare(_entity, target, _context), do: {:ok, target}

  @impl true
  def execute(entity, target, context) do
    opts =
      []
      |> put_if(:device_store, value(context, :device_store))
      |> put_if(:preset_store, value(context, :preset_store))
      |> put_if(:mqtt_client, value(context, :mqtt_client))
      |> put_if(:base_topic, value(context, :base_topic))

    action_id = value(context, :action_id) || Zaik.Home.ActionVerifier.new_id("cover")
    verification = register_verification(action_id, entity.name, target, context)

    with {:ok, blind_target} <- blind_target(target),
         {:ok, result} <- Zaik.Home.Blinds.control(entity.name, blind_target, opts) do
      outcome = published_and_await(verification, action_id, context)

      {:ok,
       %{
         action_id: action_id,
         entity_id: entity.id,
         device: entity.name,
         capability: "cover",
         target: target,
         topic: result.topic,
         payload: result.payload,
         status: if(outcome.verified, do: "verified", else: "accepted"),
         verified: outcome.verified,
         verification_status: outcome.status,
         verification_expires_at: Map.get(outcome, :expires_at),
         observed_at: Map.get(outcome, :observed_at),
         observed: Map.get(outcome, :observed),
         requested_at: DateTime.to_iso8601(result.requested_at)
       }}
    else
      {:error, reason} ->
        cancel_verification(verification, action_id, reason)
        {:error, reason}
    end
  end

  defp register_verification(action_id, device, target, context) do
    cfg = Zaik.Home.ActionVerifier.config()
    server = action_verifier(context)

    if verification_enabled?(context, cfg, server) do
      case Zaik.Home.ActionVerifier.register(action_id, device, "cover", target,
             server: server,
             timeout_ms: cfg.timeout_ms,
             ledger_key: value(context, :ledger_action_id),
             ledger: value(context, :action_ledger)
           ) do
        {:ok, _status} -> {:tracked, server, cfg}
        {:error, reason} -> {:unavailable, reason}
      end
    else
      :disabled
    end
  catch
    :exit, reason -> {:unavailable, reason}
  end

  defp published_and_await({:tracked, server, cfg}, action_id, context) do
    case Zaik.Home.ActionVerifier.published(action_id, server: server) do
      {:ok, published} ->
        if value(context, :defer_verification_wait) == true do
          published
        else
          wait_ms = value(context, :verification_wait_ms) || cfg.wait_ms
          Zaik.Home.ActionVerifier.await(action_id, wait_ms, server: server)
        end

      {:error, reason} ->
        unavailable_status(action_id, reason)
    end
  catch
    :exit, reason -> unavailable_status(action_id, reason)
  end

  defp published_and_await({:unavailable, reason}, action_id, _context),
    do: unavailable_status(action_id, reason)

  defp published_and_await(:disabled, action_id, _context),
    do: unavailable_status(action_id, :disabled)

  defp cancel_verification({:tracked, server, _cfg}, action_id, reason) do
    Zaik.Home.ActionVerifier.cancel(action_id, reason, server: server)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp cancel_verification(_verification, _action_id, _reason), do: :ok

  defp action_verifier(context) do
    case Map.fetch(context, :action_verifier) do
      {:ok, server} -> server
      :error -> Map.get(context, "action_verifier", Zaik.Home.ActionVerifier)
    end
  end

  defp verification_enabled?(context, cfg, server) do
    setting(context, :verify_actions, true) != false and cfg.enabled and
      process_available?(server)
  end

  defp process_available?(server) when is_pid(server), do: Process.alive?(server)
  defp process_available?(server) when is_atom(server), do: not is_nil(Process.whereis(server))
  defp process_available?(_server), do: false

  defp unavailable_status(action_id, reason) do
    %{
      action_id: action_id,
      status: "unavailable",
      verified: false,
      reason: inspect(reason)
    }
  end

  defp blind_target(%{"position" => position}), do: {:ok, {:position, position}}
  defp blind_target(%{"state" => state}), do: {:ok, {:state, state}}
  defp blind_target(%{"preset" => preset}), do: {:ok, {:preset, preset}}
  defp blind_target(_target), do: {:error, :invalid_cover_target}

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  defp setting(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key), default)
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

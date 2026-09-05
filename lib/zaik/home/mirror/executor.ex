defmodule Zaik.Home.Mirror.Executor do
  @moduledoc """
  Virtual cover executor used by mirror-world scenarios.

  It follows the production action-verification protocol but never publishes
  MQTT or touches a physical adapter.
  """

  @behaviour Zaik.Home.Executor

  @impl true
  def capability, do: "cover"

  @impl true
  def prepare(entity, %{"preset" => preset_name}, context) do
    store = value(context, :preset_store)

    with true <- not is_nil(store),
         {:ok, preset} <-
           Zaik.Home.DevicePresetStore.get(
             entity.name,
             preset_name,
             [capability: "cover"],
             store
           ),
         target when is_map(target) <- preset["target"],
         {:ok, target} <- Zaik.Home.Capabilities.Cover.validate_target(target) do
      {:ok, target}
    else
      false -> {:error, {:preset_not_found, preset_name}}
      {:error, :not_found} -> {:error, {:preset_not_found, preset_name}}
      nil -> {:error, {:preset_not_found, preset_name}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:invalid_preset_target, preset_name}}
    end
  end

  def prepare(_entity, target, _context), do: {:ok, target}

  @impl true
  def execute(entity, target, context) do
    mirror_store = value(context, :mirror_store)
    verifier = value(context, :action_verifier)
    action_id = value(context, :action_id) || Zaik.Home.ActionVerifier.new_id("mirror")
    cfg = Zaik.Home.ActionVerifier.config()

    with true <- is_pid(mirror_store),
         true <- process_available?(verifier),
         {:ok, _registered} <-
           Zaik.Home.ActionVerifier.register(action_id, entity.name, "cover", target,
             server: verifier,
             timeout_ms: cfg.timeout_ms,
             ledger_key: value(context, :ledger_action_id),
             ledger: value(context, :action_ledger)
           ),
         {:ok, _accepted} <-
           Zaik.Home.Mirror.Store.accept(
             mirror_store,
             entity,
             "cover",
             target,
             action_id
           ),
         {:ok, published} <- Zaik.Home.ActionVerifier.published(action_id, server: verifier),
         :ok <- Zaik.Home.Mirror.Store.commit(mirror_store, action_id) do
      outcome =
        if value(context, :defer_verification_wait) == true do
          published
        else
          wait_ms = value(context, :verification_wait_ms) || cfg.wait_ms
          Zaik.Home.ActionVerifier.await(action_id, wait_ms, server: verifier)
        end

      {:ok,
       %{
         action_id: action_id,
         entity_id: entity.id,
         device: entity.name,
         capability: "cover",
         target: target,
         adapter: "mirror",
         status: if(outcome.verified, do: "verified", else: "accepted"),
         verified: outcome.verified,
         verification_status: outcome.status,
         verification_expires_at: Map.get(outcome, :expires_at),
         observed_at: Map.get(outcome, :observed_at),
         observed: Map.get(outcome, :observed),
         requested_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    else
      false ->
        {:error, :mirror_context_unavailable}

      {:error, reason} ->
        cancel_verification(verifier, action_id, reason)
        {:error, reason}
    end
  end

  defp cancel_verification(verifier, action_id, reason) do
    if process_available?(verifier) do
      Zaik.Home.ActionVerifier.cancel(action_id, reason, server: verifier)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp process_available?(server) when is_pid(server), do: Process.alive?(server)
  defp process_available?(_server), do: false
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

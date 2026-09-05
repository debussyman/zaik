defmodule Zaik.Home.ActionRetryPolicy do
  @moduledoc """
  Deterministic retry eligibility for accepted but unverified home actions.

  The policy never retries merely because verification timed out. It first
  requires a fresh current-state report proving that the desired target has not
  converged, enforces a cooldown and retry budget, and only permits explicitly
  idempotent low-risk capability targets.
  """

  @default_max_attempts 2
  @default_cooldown_ms 30_000
  @default_settle_ms 5_000
  @default_max_state_age_ms 120_000
  @allowed_tools ["control_device", "execute_home_plan"]
  @retryable_capabilities ["cover"]

  def config do
    configured = Application.get_env(:zaik, :home_action_retries, [])

    %{
      enabled: Keyword.get(configured, :enabled, true),
      max_attempts: Keyword.get(configured, :max_attempts, @default_max_attempts),
      cooldown_ms: Keyword.get(configured, :cooldown_ms, @default_cooldown_ms),
      settle_ms: Keyword.get(configured, :settle_ms, @default_settle_ms),
      max_state_age_ms: Keyword.get(configured, :max_state_age_ms, @default_max_state_age_ms)
    }
  end

  def evaluate(entry, context \\ %{}, opts \\ [])

  def evaluate(entry, context, opts) when is_map(entry) and is_map(context) do
    cfg = Map.merge(config(), Map.new(opts))
    ledger = setting(context, :action_ledger, Zaik.Home.ActionLedger)
    retries = retry_entries(entry.idempotency_key, ledger)
    outcomes = action_outcomes(entry)

    cond do
      not cfg.enabled ->
        decision(false, "disabled", entry, retries, outcomes)

      entry.tool not in @allowed_tools ->
        decision(false, "unsupported_tool", entry, retries, outcomes)

      entry.status != "succeeded" or not is_map(entry.result) ->
        decision(false, "original_action_not_accepted", entry, retries, outcomes)

      outcomes == [] ->
        decision(false, "missing_action_outcomes", entry, retries, outcomes)

      length(retries) >= cfg.max_attempts ->
        decision(false, "retry_budget_exhausted", entry, retries, outcomes)

      cooldown_active?(retries, cfg.cooldown_ms) ->
        decision(false, "retry_cooldown_active", entry, retries, outcomes)

      true ->
        evaluate_outcomes(entry, outcomes, retries, context, cfg)
    end
  end

  def evaluate(_entry, _context, _opts), do: {:error, :invalid_action_entry}

  defp evaluate_outcomes(entry, outcomes, retries, context, cfg) do
    evaluated = Enum.map(outcomes, &evaluate_outcome(&1, context, cfg))
    retryable = Enum.filter(evaluated, &(&1.disposition == :retryable))
    converged = Enum.filter(evaluated, &(&1.disposition == :already_converged))
    waiting = Enum.filter(evaluated, &(&1.disposition == :waiting))
    blocked = Enum.filter(evaluated, &(&1.disposition == :blocked))

    cond do
      waiting != [] ->
        decision(false, "verification_still_pending", entry, retries, evaluated)

      blocked != [] ->
        reason = blocked |> hd() |> Map.fetch!(:reason)
        decision(false, reason, entry, retries, evaluated)

      retryable == [] and converged != [] ->
        decision(false, "already_converged", entry, retries, evaluated,
          reconciled_action_ids: action_ids(converged)
        )

      retryable != [] ->
        retry_args = retry_args(entry, retryable)

        decision(true, "fresh_state_not_converged", entry, retries, evaluated,
          retry_args: retry_args,
          reconciled_action_ids: action_ids(converged)
        )

      true ->
        decision(false, "nothing_retryable", entry, retries, evaluated)
    end
  end

  defp evaluate_outcome(outcome, context, cfg) do
    cond do
      outcome.verified ->
        Map.merge(outcome, %{disposition: :already_converged, reason: "already_verified"})

      outcome.capability not in @retryable_capabilities ->
        Map.merge(outcome, %{disposition: :blocked, reason: "capability_not_retryable"})

      verification_pending?(outcome) ->
        Map.merge(outcome, %{disposition: :waiting, reason: "verification_still_pending"})

      not settled?(outcome, cfg.settle_ms) ->
        Map.merge(outcome, %{disposition: :waiting, reason: "settle_window_active"})

      true ->
        evaluate_current_state(outcome, context, cfg)
    end
  end

  defp evaluate_current_state(outcome, context, cfg) do
    store = setting(context, :device_store, Zaik.Home.DeviceStore)

    case Zaik.Home.DeviceStore.find_device(store, outcome.device) do
      {:ok, device} ->
        cond do
          Zaik.Home.ActionVerifier.converged?(
            outcome.capability,
            outcome.target,
            device.payload
          ) ->
            Map.merge(outcome, %{
              disposition: :already_converged,
              reason: "current_state_converged",
              observed_at: format_datetime(device.received_at),
              observed: target_observation(outcome.target, device.payload)
            })

          fresh_after_request?(device.received_at, outcome.requested_at, cfg.max_state_age_ms) ->
            Map.merge(outcome, %{
              disposition: :retryable,
              reason: "fresh_state_not_converged",
              observed_at: format_datetime(device.received_at)
            })

          true ->
            Map.merge(outcome, %{
              disposition: :blocked,
              reason: "fresh_post_action_state_required",
              observed_at: format_datetime(device.received_at)
            })
        end

      {:error, :not_found} ->
        Map.merge(outcome, %{disposition: :blocked, reason: "device_not_found"})

      {:error, {:ambiguous, _devices}} ->
        Map.merge(outcome, %{disposition: :blocked, reason: "device_lookup_ambiguous"})

      {:error, _reason} ->
        Map.merge(outcome, %{disposition: :blocked, reason: "device_state_unavailable"})
    end
  catch
    :exit, _reason ->
      Map.merge(outcome, %{disposition: :blocked, reason: "device_state_unavailable"})
  end

  defp action_outcomes(%{tool: "execute_home_plan", result: result}) do
    result
    |> value(:actions)
    |> List.wrap()
    |> Enum.map(fn completed ->
      action = value(completed, :action) || %{}
      action_result = value(completed, :result) || %{}
      outcome(action_result, action)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp action_outcomes(%{result: result}) when is_map(result) do
    case outcome(result, result) do
      nil -> []
      outcome -> [outcome]
    end
  end

  defp action_outcomes(_entry), do: []

  defp outcome(result, action) do
    device = value(result, :device) || value(action, :device)
    capability = value(result, :capability) || value(action, :capability)
    target = value(result, :target) || value(action, :target)

    if is_binary(device) and is_binary(capability) and is_map(target) do
      %{
        action_id: value(result, :action_id),
        device: device,
        capability: capability,
        target: target,
        verified: value(result, :verified) == true,
        verification_status: value(result, :verification_status),
        verification_expires_at: parse_datetime(value(result, :verification_expires_at)),
        requested_at: parse_datetime(value(result, :requested_at))
      }
    end
  end

  defp verification_pending?(outcome) do
    status = outcome.verification_status

    status in ["registered", "pending"] and
      case outcome.verification_expires_at do
        %DateTime{} = expires_at -> DateTime.compare(DateTime.utc_now(), expires_at) == :lt
        nil -> true
      end
  end

  defp settled?(%{requested_at: nil}, _settle_ms), do: false

  defp settled?(%{requested_at: requested_at}, settle_ms) do
    DateTime.diff(DateTime.utc_now(), requested_at, :millisecond) >= settle_ms
  end

  defp fresh_after_request?(%DateTime{} = received_at, %DateTime{} = requested_at, max_age_ms) do
    now = DateTime.utc_now()

    DateTime.compare(received_at, requested_at) in [:eq, :gt] and
      DateTime.diff(now, received_at, :millisecond) <= max_age_ms
  end

  defp fresh_after_request?(_received_at, _requested_at, _max_age_ms), do: false

  defp retry_args(%{tool: "execute_home_plan", result: result}, outcomes) do
    %{
      "goal" => "Retry unverified actions from plan #{value(result, :plan_id) || "unknown"}",
      "actions" =>
        Enum.map(outcomes, fn outcome ->
          %{
            "device" => outcome.device,
            "capability" => outcome.capability,
            "target" => outcome.target
          }
        end)
    }
  end

  defp retry_args(_entry, [outcome]) do
    %{
      "device" => outcome.device,
      "capability" => outcome.capability,
      "target" => outcome.target
    }
  end

  defp target_observation(target, payload) do
    target
    |> Map.keys()
    |> Enum.reduce(%{}, fn key, observed ->
      string_key = to_string(key)

      case Map.fetch(payload, string_key) do
        {:ok, value} -> Map.put(observed, string_key, value)
        :error -> observed
      end
    end)
    |> then(fn observed ->
      if value(target, :state) in ["OPEN", "CLOSE"] and not is_nil(value(payload, :position)) do
        Map.put(observed, "position", value(payload, :position))
      else
        observed
      end
    end)
  end

  defp retry_entries(key, ledger) do
    if process_available?(ledger), do: Zaik.Home.ActionLedger.retries_for(key, ledger), else: []
  catch
    :exit, _reason -> []
  end

  defp cooldown_active?([], _cooldown_ms), do: false

  defp cooldown_active?(retries, cooldown_ms) do
    latest = retries |> List.last() |> Map.get(:updated_at) |> parse_datetime()

    match?(%DateTime{}, latest) and
      DateTime.diff(DateTime.utc_now(), latest, :millisecond) < cooldown_ms
  end

  defp decision(eligible, reason, entry, retries, outcomes, extra \\ []) do
    {:ok,
     %{
       eligible: eligible,
       reason: reason,
       action_id: entry.idempotency_key,
       original_tool: entry.tool,
       attempts_used: length(retries),
       outcomes: outcomes,
       retry_args: Keyword.get(extra, :retry_args),
       reconciled_action_ids: Keyword.get(extra, :reconciled_action_ids, [])
     }}
  end

  defp action_ids(outcomes), do: outcomes |> Enum.map(& &1.action_id) |> Enum.reject(&is_nil/1)

  defp process_available?(server) when is_pid(server), do: Process.alive?(server)
  defp process_available?(server) when is_atom(server), do: not is_nil(Process.whereis(server))
  defp process_available?(_server), do: false

  defp setting(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key), default)
    end
  end

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil
  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

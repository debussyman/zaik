defmodule Zaik.Home.ActionVerifier do
  @moduledoc """
  Correlates accepted home actions with later adapter state reports.

  Correlation is local and temporal: executors register a generated action ID
  and a validated semantic target before publishing. Adapter handlers then
  report newly received device state. A target is only marked verified when a
  post-registration report converges on that target.

  Correlation records are intentionally runtime state. Stale and duplicate
  observations are ignored, and a conflicting target for the same pending
  entity capability is rejected before execution. Verified terminal outcomes
  are reconciled into the persistent action ledger when available.
  """

  use GenServer

  @default_timeout_ms 30_000
  @default_retention_ms 300_000
  @default_position_tolerance 2

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def config do
    configured = Application.get_env(:zaik, :home_action_verification, [])

    %{
      enabled: Keyword.get(configured, :enabled, true),
      timeout_ms: Keyword.get(configured, :timeout_ms, @default_timeout_ms),
      wait_ms: Keyword.get(configured, :wait_ms, 1_500),
      retention_ms: Keyword.get(configured, :retention_ms, @default_retention_ms),
      clock: Keyword.get(configured, :clock),
      position_tolerance:
        Keyword.get(configured, :position_tolerance, @default_position_tolerance)
    }
  end

  def new_id(prefix \\ "action") do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    "#{prefix}_#{suffix}"
  end

  def register(action_id, device, capability, target, opts \\ [])
      when is_binary(action_id) and is_binary(device) and is_map(target) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:register, action_id, device, capability, target, opts})
  end

  def published(action_id, opts \\ []) when is_binary(action_id) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:published, action_id})
  end

  def cancel(action_id, reason, opts \\ []) when is_binary(action_id) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:cancel, action_id, reason})
  end

  def observe(device, payload, observed_at \\ DateTime.utc_now(), opts \\ [])
      when is_binary(device) and is_map(payload) do
    GenServer.cast(
      Keyword.get(opts, :server, __MODULE__),
      {:observe, device, payload, normalize_datetime(observed_at)}
    )
  end

  def status(action_id, opts \\ []) when is_binary(action_id) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:status, action_id})
  end

  def pending(opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), :pending)
  end

  def barrier(server \\ __MODULE__), do: GenServer.call(server, :barrier)

  def await(action_id, timeout_ms, opts \\ []) when is_binary(action_id) do
    case await_many([action_id], timeout_ms, opts) do
      %{^action_id => result} -> result
    end
  end

  def await_many(action_ids, timeout_ms, opts \\ []) when is_list(action_ids) do
    server = Keyword.get(opts, :server, __MODULE__)
    deadline = System.monotonic_time(:millisecond) + max(timeout_ms, 0)
    await_statuses(Enum.uniq(action_ids), server, deadline)
  end

  @doc """
  Validate whether an adapter payload has converged on a typed capability target.
  """
  def converged?(capability, target, payload, opts \\ [])
      when is_map(target) and is_map(payload) do
    cfg = Map.merge(config(), Map.new(opts))
    converged_target?(to_string(capability), target, payload, cfg)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       actions: %{},
       observations: %{},
       config: Map.merge(config(), Map.new(opts))
     }}
  end

  @impl true
  def handle_call({:register, action_id, device, capability, target, opts}, _from, state) do
    device_key = normalize_device(device)
    capability = to_string(capability)

    case pending_conflict(state.actions, action_id, device_key, capability, target) do
      nil ->
        now = Zaik.Time.now(state.config.clock)
        timeout_ms = Keyword.get(opts, :timeout_ms, state.config.timeout_ms)
        token = make_ref()

        action = %{
          action_id: action_id,
          token: token,
          device: device,
          device_key: device_key,
          capability: capability,
          target: target,
          status: :registered,
          registered_at: now,
          published_at: nil,
          expires_at: DateTime.add(now, timeout_ms, :millisecond),
          observed_at: nil,
          observed: nil,
          reason: nil,
          ledger_key: Keyword.get(opts, :ledger_key),
          ledger: Keyword.get(opts, :ledger, Zaik.Home.ActionLedger)
        }

        Zaik.Time.send_after(
          state.config.clock,
          self(),
          {:expire, action_id, token},
          timeout_ms
        )

        actions = Map.put(state.actions, action_id, action)
        {:reply, {:ok, public_status(action)}, %{state | actions: actions}}

      conflict ->
        {:reply, {:error, {:conflicting_action_pending, conflict.action_id}}, state}
    end
  end

  def handle_call({:published, action_id}, _from, state) do
    case Map.fetch(state.actions, action_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, action} ->
        action = %{action | status: :pending, published_at: Zaik.Time.now(state.config.clock)}
        {action, state} = maybe_verify_from_latest(action, state)
        {:reply, {:ok, public_status(action)}, put_action(state, action)}
    end
  end

  def handle_call({:cancel, action_id, reason}, _from, state) do
    case Map.fetch(state.actions, action_id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, action} ->
        action = %{action | status: :cancelled, reason: inspect(reason)}
        schedule_cleanup(action, state.config)
        notify_ledger(action)
        {:reply, :ok, put_action(state, action)}
    end
  end

  def handle_call(:pending, _from, state) do
    pending =
      state.actions
      |> Map.values()
      |> Enum.filter(&(&1.status in [:registered, :pending]))
      |> Enum.sort_by(&{&1.device_key, &1.capability, &1.action_id})
      |> Enum.map(&public_status/1)

    {:reply, pending, state}
  end

  def handle_call(:barrier, _from, state), do: {:reply, :ok, state}

  def handle_call({:status, action_id}, _from, state) do
    reply =
      case Map.fetch(state.actions, action_id) do
        {:ok, action} -> {:ok, public_status(action)}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:observe, device, payload, observed_at}, state) do
    device_key = normalize_device(device)
    observation = %{payload: payload, observed_at: observed_at}

    if stale_or_duplicate_observation?(Map.get(state.observations, device_key), observation) do
      {:noreply, state}
    else
      observations = Map.put(state.observations, device_key, observation)
      state = %{state | observations: observations}

      actions =
        Enum.reduce(state.actions, state.actions, fn {action_id, action}, actions ->
          if action.device_key == device_key and action.status == :pending and
               new_enough?(observation, action) and
               converged_target?(action.capability, action.target, payload, state.config) do
            verified = %{
              action
              | status: :verified,
                observed_at: observed_at,
                observed: relevant_observation(action.target, payload)
            }

            schedule_cleanup(verified, state.config)
            notify_ledger(verified)
            Map.put(actions, action_id, verified)
          else
            actions
          end
        end)

      {:noreply, %{state | actions: actions}}
    end
  end

  @impl true
  def handle_info({:expire, action_id, token}, state) do
    case Map.get(state.actions, action_id) do
      %{status: status, token: ^token} = action when status in [:registered, :pending] ->
        action = %{action | status: :expired, reason: "verification_timeout"}
        schedule_cleanup(action, state.config)
        notify_ledger(action)
        {:noreply, put_action(state, action)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:cleanup, action_id, token}, state) do
    actions =
      case Map.get(state.actions, action_id) do
        %{token: ^token} -> Map.delete(state.actions, action_id)
        _ -> state.actions
      end

    {:noreply, %{state | actions: actions}}
  end

  defp pending_conflict(actions, action_id, device_key, capability, target) do
    Enum.find_value(actions, fn {_existing_id, action} ->
      if action.action_id != action_id and action.device_key == device_key and
           action.capability == capability and action.status in [:registered, :pending] and
           action.target != target do
        action
      end
    end)
  end

  defp stale_or_duplicate_observation?(nil, _incoming), do: false

  defp stale_or_duplicate_observation?(current, incoming) do
    case DateTime.compare(incoming.observed_at, current.observed_at) do
      :lt -> true
      :eq -> incoming.payload == current.payload
      :gt -> false
    end
  end

  defp maybe_verify_from_latest(action, state) do
    case Map.get(state.observations, action.device_key) do
      %{payload: payload} = observation ->
        if new_enough?(observation, action) and
             converged_target?(action.capability, action.target, payload, state.config) do
          verified = %{
            action
            | status: :verified,
              observed_at: observation.observed_at,
              observed: relevant_observation(action.target, payload)
          }

          schedule_cleanup(verified, state.config)
          notify_ledger(verified)
          {verified, state}
        else
          {action, state}
        end

      nil ->
        {action, state}
    end
  end

  defp converged_target?("cover", target, payload, cfg) do
    cond do
      position = value(target, :position) ->
        target_position?(position, value(payload, :position), cfg.position_tolerance)

      state = value(target, :state) ->
        target_state?(state, payload, cfg.position_tolerance)

      true ->
        false
    end
  end

  defp converged_target?(_capability, _target, _payload, _cfg), do: false

  defp target_state?(state, payload, tolerance) do
    state = state |> to_string() |> String.upcase()
    actual_state = value(payload, :state)
    actual_position = value(payload, :position)

    case state do
      "OPEN" -> target_position?(0, actual_position, tolerance)
      "CLOSE" -> target_position?(100, actual_position, tolerance)
      "STOP" -> is_binary(actual_state) and String.upcase(actual_state) == "STOP"
      _ -> false
    end
  end

  defp target_position?(target, actual, tolerance) do
    with {:ok, target} <- number(target),
         {:ok, actual} <- number(actual) do
      abs(target - actual) <= tolerance
    else
      _ -> false
    end
  end

  defp number(value) when is_integer(value) or is_float(value), do: {:ok, value * 1.0}

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp number(_value), do: :error

  defp new_enough?(observation, action) do
    DateTime.compare(observation.observed_at, action.registered_at) in [:eq, :gt]
  end

  defp relevant_observation(target, payload) do
    target
    |> Map.keys()
    |> Enum.reduce(%{}, fn key, acc ->
      string_key = to_string(key)

      case Map.fetch(payload, string_key) do
        {:ok, value} ->
          Map.put(acc, string_key, value)

        :error ->
          case Map.fetch(payload, key) do
            {:ok, value} -> Map.put(acc, string_key, value)
            :error -> acc
          end
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

  defp await_statuses(action_ids, server, deadline) do
    statuses =
      Map.new(action_ids, fn action_id ->
        result =
          case status(action_id, server: server) do
            {:ok, result} ->
              result

            {:error, reason} ->
              %{
                action_id: action_id,
                status: "unavailable",
                verified: false,
                reason: inspect(reason)
              }
          end

        {action_id, result}
      end)

    terminal? =
      Enum.all?(statuses, fn {_id, result} -> result.status not in ["registered", "pending"] end)

    remaining = deadline - System.monotonic_time(:millisecond)

    if terminal? or remaining <= 0 do
      statuses
    else
      Process.sleep(min(25, remaining))
      await_statuses(action_ids, server, deadline)
    end
  end

  defp public_status(action) do
    %{
      action_id: action.action_id,
      device: action.device,
      capability: action.capability,
      target: action.target,
      status: Atom.to_string(action.status),
      verified: action.status == :verified,
      registered_at: format_datetime(action.registered_at),
      published_at: format_datetime(action.published_at),
      expires_at: format_datetime(action.expires_at),
      observed_at: format_datetime(action.observed_at),
      observed: action.observed,
      reason: action.reason
    }
  end

  defp notify_ledger(%{ledger_key: ledger_key, ledger: ledger} = action)
       when is_binary(ledger_key) do
    if process_available?(ledger) do
      Zaik.Home.ActionLedger.mark_verification(
        ledger_key,
        action.action_id,
        public_status(action),
        ledger
      )
    end

    :ok
  end

  defp notify_ledger(_action), do: :ok

  defp put_action(state, action),
    do: %{state | actions: Map.put(state.actions, action.action_id, action)}

  defp schedule_cleanup(action, config) do
    Zaik.Time.send_after(
      config.clock,
      self(),
      {:cleanup, action.action_id, action.token},
      config.retention_ms
    )
  end

  defp process_available?(server) when is_pid(server), do: Process.alive?(server)
  defp process_available?(server) when is_atom(server), do: not is_nil(Process.whereis(server))
  defp process_available?(_server), do: false

  defp normalize_device(value),
    do: value |> to_string() |> String.trim() |> String.downcase()

  defp normalize_datetime(%DateTime{} = datetime), do: datetime
  defp normalize_datetime(_value), do: DateTime.utc_now()

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

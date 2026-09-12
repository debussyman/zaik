defmodule Zaik.Home.Autonomy.Engine do
  @moduledoc """
  Supervised shadow/advisory evaluation pipeline for home policies.

  This first slice is deliberately inert: it builds context, evaluates policies,
  arbitrates, reconciles, and records a decision. Canary and active execution
  are rejected until rollout gates and action budgets are implemented.
  """

  use GenServer

  @safe_modes [:shadow, :advisory]

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put_new(server_opts, :name, __MODULE__))
  end

  def config do
    configured = Application.get_env(:zaik, :home_autonomy, [])

    %{
      enabled: Keyword.get(configured, :enabled, false),
      mode: Keyword.get(configured, :mode, :shadow),
      max_state_age_seconds: Keyword.get(configured, :max_state_age_seconds, 120),
      context_window_minutes: Keyword.get(configured, :context_window_minutes, 180),
      event_debounce_ms: Keyword.get(configured, :event_debounce_ms, 500),
      event_min_interval_ms: Keyword.get(configured, :event_min_interval_ms, 60_000),
      evaluation_timeout_ms: Keyword.get(configured, :evaluation_timeout_ms, 30_000),
      max_concurrent_evaluations: Keyword.get(configured, :max_concurrent_evaluations, 2),
      occupancy_absence_debounce_ms:
        Keyword.get(configured, :occupancy_absence_debounce_ms, 5 * 60_000),
      subscribe_events: Keyword.get(configured, :subscribe_events, false),
      decision_db_path:
        Keyword.get(configured, :decision_db_path, Zaik.Home.HistoryStore.config().db_path)
    }
  end

  def evaluate(query, opts \\ [], server \\ __MODULE__) when is_binary(query),
    do: GenServer.call(server, {:evaluate, query, opts}, Keyword.get(opts, :timeout, 30_000))

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  def pause(reason, paused_by \\ "operator", server \\ __MODULE__),
    do: GenServer.call(server, {:pause, to_string(reason), to_string(paused_by)})

  def resume(resumed_by \\ "operator", server \\ __MODULE__),
    do: GenServer.call(server, {:resume, to_string(resumed_by)})

  def set_mode(mode, changed_by \\ "operator", server \\ __MODULE__),
    do: GenServer.call(server, {:set_mode, mode, to_string(changed_by)})

  @impl true
  def init(opts) do
    cfg = Map.merge(config(), Map.new(opts))
    event_bus = Map.get(cfg, :event_bus, Zaik.Home.EventBus)

    if cfg.subscribe_events and process_available?(event_bus) do
      :ok = Zaik.Home.EventBus.subscribe(event_bus, self())
    end

    state = %{
      config: cfg,
      event_bus: event_bus,
      pending: %{},
      running: %{},
      stability_wakeups: %{},
      last_evaluated_ms: %{},
      last_decision: nil,
      pause: nil,
      mode_changed_by: "configuration"
    }

    {:ok, restore_settle_wakeups(state)}
  end

  @impl true
  def handle_call({:evaluate, _query, _request_opts}, _from, %{pause: pause} = state)
      when not is_nil(pause) do
    {:reply, {:error, {:autonomy_paused, pause}}, state}
  end

  def handle_call({:evaluate, query, request_opts}, _from, state) do
    mode = Keyword.get(request_opts, :mode, state.config.mode)
    reply = evaluate_request(query, mode, state.config, request_opts)
    state = if match?({:ok, _}, reply), do: %{state | last_decision: elem(reply, 1)}, else: state
    {:reply, reply, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       mode: state.config.mode,
       mode_changed_by: state.mode_changed_by,
       paused: not is_nil(state.pause),
       pause: state.pause,
       subscribe_events: state.config.subscribe_events,
       pending_count: map_size(state.pending),
       running_count: map_size(state.running),
       stability_wakeup_count: map_size(state.stability_wakeups),
       last_decision: state.last_decision
     }, state}
  end

  def handle_call({:pause, reason, paused_by}, _from, state) do
    pause = %{
      reason: if(String.trim(reason) == "", do: "operator pause", else: String.trim(reason)),
      paused_by: paused_by,
      paused_at: state.config |> Map.get(:clock) |> Zaik.Time.now() |> DateTime.to_iso8601()
    }

    {:reply, {:ok, pause}, %{state | pause: pause}}
  end

  def handle_call({:resume, resumed_by}, _from, state) do
    result = %{
      resumed_by: resumed_by,
      resumed_at: state.config |> Map.get(:clock) |> Zaik.Time.now() |> DateTime.to_iso8601()
    }

    {:reply, {:ok, result}, %{state | pause: nil}}
  end

  def handle_call({:set_mode, mode, changed_by}, _from, state)
      when mode in @safe_modes or mode == :off do
    {:reply, {:ok, mode},
     %{state | config: Map.put(state.config, :mode, mode), mode_changed_by: changed_by}}
  end

  def handle_call({:set_mode, mode, _changed_by}, _from, state),
    do: {:reply, {:error, {:execution_mode_not_enabled, mode}}, state}

  @impl true
  def handle_info({:zaik_home_event, %{type: :device_observed} = event}, %{pause: nil} = state) do
    if relevant_event?(event) do
      {key, query} = event_scope(event, state.config)

      {:noreply, schedule_event(state, key, query, event)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:zaik_home_event, %{type: :device_observed}}, state), do: {:noreply, state}

  def handle_info({:zaik_home_event, %{type: :occupancy_changed}}, %{pause: pause} = state)
      when not is_nil(pause),
      do: {:noreply, state}

  def handle_info({:zaik_home_event, %{type: :occupancy_changed, area: area} = event}, state) do
    {:noreply, schedule_event(state, area, area, Map.put(event, :device, area))}
  end

  def handle_info({:evaluate_event, key}, %{pause: pause} = state) when not is_nil(pause) do
    {:noreply, update_in(state.pending, &Map.delete(&1, key))}
  end

  def handle_info({:evaluate_event, key}, state) do
    %{event: event} = Map.fetch!(state.pending, key)

    state =
      state
      |> update_in([:pending], &Map.delete(&1, key))
      |> put_in([:last_evaluated_ms, key], Zaik.Time.monotonic_ms(Map.get(state.config, :clock)))

    opts =
      state.config
      |> Map.to_list()
      |> Keyword.put(:mode, state.config.mode)
      |> Keyword.put(:changed_dependencies, event_dependencies(event))

    {:noreply, start_event_evaluation(state, key, event.query, opts)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, state}

      {entry, running} ->
        Process.demonitor(ref, [:flush])
        state = %{state | running: running}

        state =
          case result do
            {:ok, decision} ->
              state
              |> Map.put(:last_decision, decision)
              |> schedule_stability_wakeup(entry.key, entry.query, decision)

            _ ->
              state
          end

        {:noreply, state}
    end
  end

  def handle_info({:stability_wakeup, key, query, token}, state) do
    case Map.get(state.stability_wakeups, key) do
      ^token when is_nil(state.pause) ->
        state = update_in(state.stability_wakeups, &Map.delete(&1, key))

        opts =
          state.config
          |> Map.to_list()
          |> Keyword.put(:mode, state.config.mode)
          |> Keyword.put(:changed_dependencies, nil)

        {:noreply, start_event_evaluation(state, key, query, opts)}

      ^token ->
        {:noreply, update_in(state.stability_wakeups, &Map.delete(&1, key))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:evaluation_timeout, ref}, state) do
    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, state}

      {%{task: task}, running} ->
        Task.shutdown(task, :brutal_kill)
        {:noreply, %{state | running: running}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | running: Map.delete(state.running, ref)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_event_evaluation(state, key, query, opts) do
    supervisor = Map.get(state.config, :task_supervisor, Zaik.Tools.TaskSupervisor)
    maximum = Map.get(state.config, :max_concurrent_evaluations, 2)

    cond do
      not process_available?(supervisor) ->
        case evaluate_request(query, state.config.mode, state.config, opts) do
          {:ok, decision} ->
            state
            |> Map.put(:last_decision, decision)
            |> schedule_stability_wakeup(key, query, decision)

          {:error, _reason} ->
            state
        end

      map_size(state.running) >= maximum ->
        changed_keys =
          opts
          |> Keyword.get(:changed_dependencies, [])
          |> Enum.map(fn
            "cover" -> "position"
            dependency -> dependency
          end)

        schedule_event(state, key, query, %{device: query, changed_keys: changed_keys})

      true ->
        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            evaluate_request(query, state.config.mode, state.config, opts)
          end)

        timer =
          Zaik.Time.send_after(
            Map.get(state.config, :clock),
            self(),
            {:evaluation_timeout, task.ref},
            Map.get(state.config, :evaluation_timeout_ms, 30_000)
          )

        put_in(state, [:running, task.ref], %{task: task, timer: timer, key: key, query: query})
    end
  end

  defp restore_settle_wakeups(state) do
    store = Map.get(state.config, :desired_state_store, Zaik.Home.Autonomy.DesiredStateStore)
    clock = Map.get(state.config, :clock)

    if process_available?(store) do
      stability = policy_stability(Map.to_list(state.config))
      now = Zaik.Time.now(clock)

      Zaik.Home.Autonomy.DesiredStateStore.active(nil, [clock: clock], store)
      |> Enum.group_by(& &1.scope)
      |> Enum.reduce(state, fn {scope, leases}, acc ->
        remaining =
          leases
          |> Enum.map(fn lease ->
            settle = get_in(stability, [lease.source_id, :settle_seconds]) || 0
            settle - elapsed_seconds(lease.created_at, now)
          end)
          |> Enum.filter(&(&1 > 0))
          |> Enum.min(fn -> nil end)

        if remaining, do: put_stability_wakeup(acc, scope, scope, remaining), else: acc
      end)
    else
      state
    end
  catch
    :exit, _reason -> state
  end

  defp schedule_stability_wakeup(state, key, query, decision) do
    retry_after =
      decision
      |> get_in([:reconciliation, :blocked])
      |> List.wrap()
      |> Enum.filter(&(Map.get(&1, :reason) in ["policy_settling", "policy_cooldown"]))
      |> Enum.map(&Map.get(&1, :retry_after_seconds))
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.min(fn -> nil end)

    if retry_after do
      put_stability_wakeup(state, key, query, retry_after)
    else
      update_in(state.stability_wakeups, &Map.delete(&1, key))
    end
  end

  defp put_stability_wakeup(state, key, query, retry_after) do
    token = make_ref()

    Zaik.Time.send_after(
      Map.get(state.config, :clock),
      self(),
      {:stability_wakeup, key, query, token},
      retry_after * 1_000
    )

    put_in(state, [:stability_wakeups, key], token)
  end

  defp elapsed_seconds(value, now) do
    with value when is_binary(value) <- value,
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      max(0, DateTime.diff(now, datetime, :second))
    else
      _ -> 0
    end
  end

  defp evaluate_request(_query, :off, _cfg, _opts), do: {:error, :autonomy_disabled}

  defp evaluate_request(_query, mode, _cfg, _opts) when mode not in @safe_modes,
    do: {:error, {:execution_mode_not_enabled, mode}}

  defp evaluate_request(query, mode, cfg, opts) do
    clock = Keyword.get(opts, :clock)
    now = Zaik.Time.now(clock)

    with {:ok, context} <-
           Zaik.Home.RoomContext.build(query,
             device_store: Keyword.get(opts, :device_store),
             history_store: Keyword.get(opts, :history_store),
             capability_opts: Keyword.get(opts, :capability_opts),
             occupancy_tracker:
               Keyword.get(
                 opts,
                 :occupancy_tracker,
                 Map.get(cfg, :occupancy_tracker, Zaik.Home.OccupancyTracker)
               ),
             clock: clock,
             window_minutes: Keyword.get(opts, :window_minutes, cfg.context_window_minutes),
             history_capabilities:
               Keyword.get(opts, :history_capabilities, [
                 "temperature_f",
                 "illuminance",
                 "presence"
               ]),
             environment_config: Keyword.get(opts, :environment_config, %{}),
             manual_override_store:
               Keyword.get(
                 opts,
                 :manual_override_store,
                 Map.get(cfg, :manual_override_store, Zaik.Home.Autonomy.ManualOverrideStore)
               ),
             desired_state_store:
               Keyword.get(
                 opts,
                 :desired_state_store,
                 Map.get(cfg, :desired_state_store, Zaik.Home.Autonomy.DesiredStateStore)
               )
           ),
         {:ok, candidates} <- evaluate_policies(context, opts, clock) do
      arbitration =
        Zaik.Home.Arbitrator.arbitrate(candidates,
          clock: clock
        )

      reconciliation =
        Zaik.Home.Reconciler.diff(arbitration, context,
          clock: clock,
          max_state_age_seconds:
            Keyword.get(opts, :max_state_age_seconds, cfg.max_state_age_seconds),
          policy_stability: policy_stability(opts)
        )

      decision = %{
        id: decision_id(context.snapshot_id, candidates, mode, now),
        mode: mode,
        query: query,
        snapshot_id: context.snapshot_id,
        status: decision_status(candidates, reconciliation),
        context: context,
        candidates: candidates,
        arbitration: arbitration,
        reconciliation: reconciliation,
        policy_fingerprint:
          Zaik.Home.Policies.Registry.fingerprint(Keyword.get(opts, :policy_registry_opts, [])),
        created_at: now
      }

      desired_store =
        Keyword.get(
          opts,
          :desired_state_store,
          Map.get(cfg, :desired_state_store, Zaik.Home.Autonomy.DesiredStateStore)
        )

      with :ok <- record_desired_states(decision, desired_store),
           :ok <- record_decision(decision, Keyword.get(opts, :decision_store)) do
        {:ok, decision}
      else
        {:error, {:desired_state_not_recorded, _} = reason} -> {:error, reason}
        {:error, reason} -> {:error, {:decision_not_recorded, reason}}
      end
    end
  end

  defp policy_stability(opts) do
    policy_opts = Keyword.get(opts, :policy_opts, [])

    opts
    |> Keyword.get(:policy_registry_opts, [])
    |> Zaik.Home.Policies.Registry.descriptors()
    |> Map.new(fn descriptor ->
      {descriptor.id,
       %{
         settle_seconds: Keyword.get(policy_opts, :settle_seconds, descriptor.settle_seconds),
         cooldown_seconds:
           Keyword.get(policy_opts, :cooldown_seconds, descriptor.cooldown_seconds)
       }}
    end)
  end

  defp evaluate_policies(context, opts, clock) do
    registry_opts = Keyword.get(opts, :policy_registry_opts, [])

    Zaik.Home.Policies.Registry.evaluate_all(
      context,
      Keyword.merge(registry_opts,
        changed_dependencies: Keyword.get(opts, :changed_dependencies),
        policy_opts:
          Keyword.merge(Keyword.get(opts, :policy_opts, []),
            clock: clock,
            capability_opts: Keyword.get(opts, :capability_opts, [])
          )
      )
    )
  end

  defp record_desired_states(_decision, nil), do: :ok
  defp record_desired_states(_decision, false), do: :ok

  defp record_desired_states(decision, store) do
    if process_available?(store) do
      case Zaik.Home.Autonomy.DesiredStateStore.record(decision, store) do
        {:ok, _rows} -> :ok
        {:error, reason} -> {:error, {:desired_state_not_recorded, reason}}
      end
    else
      :ok
    end
  catch
    :exit, reason -> {:error, {:desired_state_not_recorded, reason}}
  end

  defp record_decision(decision, nil) do
    if process_available?(Zaik.Home.Autonomy.DecisionStore) do
      record_decision(decision, Zaik.Home.Autonomy.DecisionStore)
    else
      :ok
    end
  end

  defp record_decision(decision, store) do
    case Zaik.Home.Autonomy.DecisionStore.record(decision, store) do
      {:ok, _stored} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp decision_status([], _reconciliation), do: "no_candidates"
  defp decision_status(_candidates, %{actions: [_ | _]}), do: "proposed"
  defp decision_status(_candidates, %{blocked: [_ | _]}), do: "blocked"
  defp decision_status(_candidates, _reconciliation), do: "satisfied"

  defp decision_id(snapshot_id, candidates, mode, now) do
    {snapshot_id, Enum.map(candidates, & &1.fingerprint), mode, DateTime.to_iso8601(now)}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("decision_" <> String.slice(&1, 0, 24)))
  end

  defp schedule_event(state, key, query, event) do
    event = Map.put(event, :query, query)

    case Map.get(state.pending, key) do
      %{event: pending_event} = pending ->
        changed_keys =
          (List.wrap(Map.get(pending_event, :changed_keys)) ++
             List.wrap(Map.get(event, :changed_keys)))
          |> Enum.uniq()

        merged_event = pending_event |> Map.merge(event) |> Map.put(:changed_keys, changed_keys)
        put_in(state, [:pending, key], %{pending | event: merged_event})

      nil ->
        clock = Map.get(state.config, :clock)
        now_ms = Zaik.Time.monotonic_ms(clock)
        last_ms = Map.get(state.last_evaluated_ms, key)
        minimum = Map.get(state.config, :event_min_interval_ms, 60_000)
        remaining = if is_integer(last_ms), do: max(0, last_ms + minimum - now_ms), else: 0
        delay = max(state.config.event_debounce_ms, remaining)

        timer =
          Zaik.Time.send_after(
            clock,
            self(),
            {:evaluate_event, key},
            delay
          )

        put_in(state, [:pending, key], %{timer: timer, event: event})
    end
  end

  defp event_scope(event, config) do
    opts =
      []
      |> put_if(:device_store, Map.get(config, :device_store))
      |> put_if(:identity_store, Map.get(config, :history_store))
      |> put_if(:capability_opts, Map.get(config, :capability_opts))

    case Zaik.Home.World.get(event.device, opts) do
      {:ok, %{area_id: area_id}} when is_binary(area_id) and area_id != "" -> {area_id, area_id}
      {:ok, entity} -> {entity.id, entity.name}
      _ -> {event.device, event.device}
    end
  catch
    :exit, _reason -> {event.device, event.device}
  end

  defp event_dependencies(event) do
    event
    |> Map.get(:changed_keys, [])
    |> Enum.flat_map(fn
      "position" -> ["cover"]
      "state" -> ["cover"]
      key when key in ["presence", "illuminance", "temperature"] -> [key]
      _key -> []
    end)
    |> Enum.uniq()
  end

  defp relevant_event?(event) do
    Enum.any?(List.wrap(Map.get(event, :changed_keys)), fn key ->
      key in ["presence", "illuminance", "temperature", "position"]
    end)
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  defp process_available?(server) when is_pid(server), do: Process.alive?(server)
  defp process_available?(server) when is_atom(server), do: not is_nil(Process.whereis(server))
  defp process_available?(_server), do: false
end

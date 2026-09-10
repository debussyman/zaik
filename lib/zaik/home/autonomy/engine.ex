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
      subscribe_events: Keyword.get(configured, :subscribe_events, false),
      decision_db_path:
        Keyword.get(configured, :decision_db_path, Zaik.Home.HistoryStore.config().db_path)
    }
  end

  def evaluate(query, opts \\ [], server \\ __MODULE__) when is_binary(query),
    do: GenServer.call(server, {:evaluate, query, opts}, Keyword.get(opts, :timeout, 30_000))

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    cfg = Map.merge(config(), Map.new(opts))
    event_bus = Map.get(cfg, :event_bus, Zaik.Home.EventBus)

    if cfg.subscribe_events and process_available?(event_bus) do
      :ok = Zaik.Home.EventBus.subscribe(event_bus, self())
    end

    {:ok, %{config: cfg, event_bus: event_bus, pending: %{}, last_decision: nil}}
  end

  @impl true
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
       subscribe_events: state.config.subscribe_events,
       pending_count: map_size(state.pending),
       last_decision: state.last_decision
     }, state}
  end

  @impl true
  def handle_info({:zaik_home_event, %{type: :device_observed} = event}, state) do
    if relevant_event?(event) do
      {key, query} = event_scope(event, state.config)

      if Map.has_key?(state.pending, key) do
        {:noreply, state}
      else
        timer =
          Zaik.Time.send_after(
            Map.get(state.config, :clock),
            self(),
            {:evaluate_event, key, Map.put(event, :query, query)},
            state.config.event_debounce_ms
          )

        {:noreply, put_in(state, [:pending, key], timer)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:evaluate_event, key, event}, state) do
    state = update_in(state.pending, &Map.delete(&1, key))

    opts =
      state.config
      |> Map.to_list()
      |> Keyword.put(:mode, state.config.mode)
      |> Keyword.put(:changed_dependencies, event_dependencies(event))

    case evaluate_request(event.query, state.config.mode, state.config, opts) do
      {:ok, decision} -> {:noreply, %{state | last_decision: decision}}
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

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
             clock: clock,
             window_minutes: Keyword.get(opts, :window_minutes, cfg.context_window_minutes),
             history_capabilities:
               Keyword.get(opts, :history_capabilities, [
                 "temperature_f",
                 "illuminance",
                 "presence"
               ]),
             environment_config: Keyword.get(opts, :environment_config, %{})
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
            Keyword.get(opts, :max_state_age_seconds, cfg.max_state_age_seconds)
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

      case record_decision(decision, Keyword.get(opts, :decision_store)) do
        :ok -> {:ok, decision}
        {:error, reason} -> {:error, {:decision_not_recorded, reason}}
      end
    end
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

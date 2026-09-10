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
      decision_db_path:
        Keyword.get(configured, :decision_db_path, Zaik.Home.HistoryStore.config().db_path)
    }
  end

  def evaluate(query, opts \\ [], server \\ __MODULE__) when is_binary(query),
    do: GenServer.call(server, {:evaluate, query, opts}, Keyword.get(opts, :timeout, 30_000))

  @impl true
  def init(opts) do
    cfg = Map.merge(config(), Map.new(opts))
    {:ok, cfg}
  end

  @impl true
  def handle_call({:evaluate, query, request_opts}, _from, cfg) do
    mode = Keyword.get(request_opts, :mode, cfg.mode)
    reply = evaluate_request(query, mode, cfg, request_opts)
    {:reply, reply, cfg}
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

  defp process_available?(server) when is_pid(server), do: Process.alive?(server)
  defp process_available?(server) when is_atom(server), do: not is_nil(Process.whereis(server))
  defp process_available?(_server), do: false
end

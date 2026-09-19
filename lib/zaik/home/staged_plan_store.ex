defmodule Zaik.Home.StagedPlanStore do
  @moduledoc """
  Durable, audited storage for preflighted staged plans.

  The store provides lifecycle, ownership, wait-cadence, and checkpoint
  boundaries. It never invokes an executor; the only current coordinator is
  restricted to isolated mirror bindings.
  """

  use GenServer
  alias Exqlite.Sqlite3

  @default_max_terminal_rows 10_000
  @default_max_run_event_rows 10_000
  @run_event_types ~w(scheduled recovered_waiting recovered_running evaluation_started waiting completed cancelled failed timed_out task_exit observation_wakeup alert_emitted)

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put_new(server_opts, :name, __MODULE__))
  end

  def persist(%Zaik.Home.StagedPlan{} = plan, attrs \\ %{}, opts \\ [], server \\ __MODULE__)
      when is_map(attrs),
      do: GenServer.call(server, {:persist, plan, attrs, opts})

  def lookup(id, opts \\ [], server \\ __MODULE__) when is_binary(id),
    do: GenServer.call(server, {:lookup, id, opts})

  def active(opts \\ [], server \\ __MODULE__), do: GenServer.call(server, {:active, opts})

  def recent(limit \\ 20, server \\ __MODULE__) when is_integer(limit),
    do: GenServer.call(server, {:recent, limit})

  def cancel(
        id,
        cancelled_by,
        reason \\ "operator cancellation",
        opts \\ [],
        server \\ __MODULE__
      )
      when is_binary(id) and is_binary(cancelled_by) and is_binary(reason),
      do: GenServer.call(server, {:cancel, id, cancelled_by, reason, opts})

  def claim_run(id, runner_id, opts \\ [], server \\ __MODULE__)
      when is_binary(id) and is_binary(runner_id),
      do: GenServer.call(server, {:claim_run, id, runner_id, opts})

  def checkpoint(id, runner_id, stage_index, result, status, opts \\ [], server \\ __MODULE__)
      when is_binary(id) and is_binary(runner_id) and is_integer(stage_index) and is_map(result),
      do: GenServer.call(server, {:checkpoint, id, runner_id, stage_index, result, status, opts})

  def wake_waiting(id, observed_at, opts \\ [], server \\ __MODULE__)
      when is_binary(id) and is_struct(observed_at, DateTime),
      do: GenServer.call(server, {:wake_waiting, id, observed_at, opts})

  def finish(id, runner_id, result, opts \\ [], server \\ __MODULE__)
      when is_binary(id) and is_binary(runner_id) and is_map(result),
      do: GenServer.call(server, {:finish, id, runner_id, result, opts})

  def stop_run(id, runner_id, status, result, opts \\ [], server \\ __MODULE__)
      when is_binary(id) and is_binary(runner_id) and is_map(result),
      do: GenServer.call(server, {:stop_run, id, runner_id, status, result, opts})

  def record_run_event(plan_id, event_type, attrs \\ %{}, opts \\ [], server \\ __MODULE__)
      when is_binary(plan_id) and is_map(attrs),
      do: GenServer.call(server, {:record_run_event, plan_id, to_string(event_type), attrs, opts})

  def run_events(plan_id, limit \\ 50, server \\ __MODULE__)
      when is_binary(plan_id) and is_integer(limit),
      do: GenServer.call(server, {:run_events, plan_id, limit})

  def run_events_by_type(plan_id, event_type, limit \\ 50, server \\ __MODULE__)
      when is_binary(plan_id) and is_integer(limit),
      do: GenServer.call(server, {:run_events_by_type, plan_id, to_string(event_type), limit})

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :db_path, Zaik.Home.HistoryStore.config().db_path) |> expand_path()
    unless path == ":memory:", do: path |> Path.dirname() |> File.mkdir_p!()

    with {:ok, conn} <- Sqlite3.open(path), :ok <- migrate(conn) do
      state = %{
        conn: conn,
        clock: Keyword.get(opts, :clock),
        event_bus: Keyword.get(opts, :event_bus, Zaik.Home.EventBus),
        max_terminal_rows: Keyword.get(opts, :max_terminal_rows, @default_max_terminal_rows),
        max_run_event_rows: Keyword.get(opts, :max_run_event_rows, @default_max_run_event_rows)
      }

      _ = expire_due(conn, Zaik.Time.now(state.clock))
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:record_run_event, plan_id, event_type, attrs, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))

    reply =
      with true <- event_type in @run_event_types,
           {:ok, _plan} <- lookup_row(state.conn, plan_id),
           :ok <-
             execute(
               state.conn,
               """
               INSERT INTO home_staged_plan_run_events
                 (plan_id, event_type, details_json, recorded_at)
               VALUES (?, ?, ?, ?)
               """,
               [
                 plan_id,
                 event_type,
                 Jason.encode!(stringify(attrs)),
                 DateTime.to_iso8601(now)
               ]
             ) do
        _ = prune_run_events(state.conn, state.max_run_event_rows)
        {:ok, %{plan_id: plan_id, event_type: event_type, recorded_at: DateTime.to_iso8601(now)}}
      else
        false -> {:error, {:invalid_staged_plan_run_event, event_type}}
        error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:run_events, plan_id, limit}, _from, state) do
    limit = max(1, min(limit, 200))

    events =
      query(
        state.conn,
        """
        SELECT id, plan_id, event_type, details_json, recorded_at
        FROM home_staged_plan_run_events
        WHERE plan_id = ?
        ORDER BY id DESC LIMIT ?
        """,
        [plan_id, limit]
      )
      |> Enum.map(&decode_run_event/1)

    {:reply, events, state}
  end

  def handle_call({:run_events_by_type, plan_id, event_type, limit}, _from, state) do
    limit = max(1, min(limit, 200))

    events =
      query(
        state.conn,
        """
        SELECT id, plan_id, event_type, details_json, recorded_at
        FROM home_staged_plan_run_events
        WHERE plan_id = ? AND event_type = ?
        ORDER BY id DESC LIMIT ?
        """,
        [plan_id, event_type, limit]
      )
      |> Enum.map(&decode_run_event/1)

    {:reply, events, state}
  end

  def handle_call({:persist, plan, attrs, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    owner = attrs |> value(:owner, "operator") |> to_string() |> String.trim()
    source = attrs |> value(:source, "operator") |> to_string() |> String.trim()
    reason = attrs |> value(:reason, "prepared staged plan") |> to_string() |> String.trim()

    reply =
      with :ok <- validate_text(:owner, owner),
           :ok <- validate_text(:source, source),
           :ok <- validate_text(:reason, reason),
           :ok <- validate_plan_lifetime(plan, now) do
        persist_plan(state, plan, owner, source, reason, now)
      end

    {:reply, reply, state}
  end

  def handle_call({:lookup, id, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    _ = expire_due(state.conn, now)
    {:reply, lookup_row(state.conn, id), state}
  end

  def handle_call({:active, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    _ = expire_due(state.conn, now)

    rows =
      query(
        state.conn,
        select_sql(
          "WHERE status IN ('prepared', 'waiting', 'running') ORDER BY julianday(prepared_at), id"
        ),
        []
      )
      |> Enum.map(&decode/1)

    {:reply, rows, state}
  end

  def handle_call({:recent, limit}, _from, state) do
    limit = max(1, min(limit, 200))
    _ = expire_due(state.conn, Zaik.Time.now(state.clock))

    rows =
      query(
        state.conn,
        select_sql("ORDER BY julianday(updated_at) DESC, id DESC LIMIT ?"),
        [limit]
      )
      |> Enum.map(&decode/1)

    {:reply, rows, state}
  end

  def handle_call({:claim_run, id, runner_id, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    _ = expire_due(state.conn, now)

    reply =
      with {:ok, current} <- lookup_row(state.conn, id),
           :ok <- claimable(current, runner_id, now),
           :ok <-
             execute(
               state.conn,
               """
               UPDATE home_staged_plans
               SET status = 'running', runner_id = ?,
                   started_at = COALESCE(started_at, ?), updated_at = ?
               WHERE id = ? AND status IN ('prepared', 'waiting', 'running')
               """,
               [runner_id, DateTime.to_iso8601(now), DateTime.to_iso8601(now), id]
             ),
           {:ok, claimed} <- lookup_row(state.conn, id) do
        {:ok, claimed}
      end

    {:reply, reply, state}
  end

  def handle_call({:checkpoint, id, runner_id, stage_index, result, status, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    status = to_string(status)

    reply =
      with true <- status in ["running", "waiting"],
           {:ok, current} <- lookup_row(state.conn, id),
           :ok <- owned_running_plan(current, runner_id),
           result = Map.put_new(result, :recorded_at, DateTime.to_iso8601(now)),
           results = checkpoint_results(current.stage_results, stringify(result), status),
           {:ok, waiting_since, next_evaluation_at, waiting_kind} <-
             wait_schedule(status, current, result, now),
           :ok <-
             execute(
               state.conn,
               """
               UPDATE home_staged_plans
               SET status = ?, current_stage = ?, stage_results_json = ?, updated_at = ?,
                   waiting_since = ?, next_evaluation_at = ?, waiting_kind = ?
               WHERE id = ? AND runner_id = ? AND status = 'running'
               """,
               [
                 status,
                 stage_index,
                 Jason.encode!(results),
                 DateTime.to_iso8601(now),
                 waiting_since,
                 next_evaluation_at,
                 waiting_kind,
                 id,
                 runner_id
               ]
             ),
           {:ok, checkpointed} <- lookup_row(state.conn, id) do
        {:ok, checkpointed}
      else
        false -> {:error, {:invalid_staged_plan_status, status}}
        error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:wake_waiting, id, observed_at, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))

    reply =
      with {:ok, current} <- lookup_row(state.conn, id),
           :ok <- observation_wakeable(current, observed_at),
           :ok <-
             execute(
               state.conn,
               """
               UPDATE home_staged_plans
               SET next_evaluation_at = ?, observation_wakeup_at = ?,
                   observation_wakeup_count = observation_wakeup_count + 1, updated_at = ?
               WHERE id = ? AND status = 'waiting'
               """,
               [
                 DateTime.to_iso8601(now),
                 DateTime.to_iso8601(observed_at),
                 DateTime.to_iso8601(now),
                 id
               ]
             ),
           {:ok, awakened} <- lookup_row(state.conn, id) do
        {:ok, awakened}
      end

    {:reply, reply, state}
  end

  def handle_call({:finish, id, runner_id, result, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))

    reply =
      with {:ok, current} <- lookup_row(state.conn, id),
           :ok <- owned_running_plan(current, runner_id),
           :ok <-
             execute(
               state.conn,
               """
               UPDATE home_staged_plans
               SET status = 'completed', final_result_json = ?, completed_at = ?, updated_at = ?,
                   next_evaluation_at = NULL, waiting_kind = NULL
               WHERE id = ? AND runner_id = ? AND status = 'running'
               """,
               [
                 Jason.encode!(stringify(result)),
                 DateTime.to_iso8601(now),
                 DateTime.to_iso8601(now),
                 id,
                 runner_id
               ]
             ),
           {:ok, completed} <- lookup_row(state.conn, id) do
        _ = prune(state.conn, state.max_terminal_rows)
        {:ok, completed}
      end

    {:reply, reply, state}
  end

  def handle_call({:stop_run, id, runner_id, status, result, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    status = to_string(status)

    reply =
      with true <- status in ["cancelled", "failed"],
           {:ok, current} <- lookup_row(state.conn, id),
           :ok <- owned_running_plan(current, runner_id),
           :ok <-
             execute(
               state.conn,
               """
               UPDATE home_staged_plans
               SET status = ?, final_result_json = ?, completed_at = ?, updated_at = ?,
                   next_evaluation_at = NULL, waiting_kind = NULL,
                   cancelled_at = CASE WHEN ? = 'cancelled' THEN COALESCE(cancelled_at, ?) ELSE cancelled_at END,
                   cancelled_by = CASE WHEN ? = 'cancelled' THEN COALESCE(cancelled_by, cancellation_requested_by, 'coordinator') ELSE cancelled_by END,
                   cancellation_reason = CASE WHEN ? = 'cancelled' THEN COALESCE(cancellation_reason, cancellation_request_reason, 'coordinator cancellation') ELSE cancellation_reason END
               WHERE id = ? AND runner_id = ? AND status = 'running'
               """,
               [
                 status,
                 Jason.encode!(stringify(result)),
                 DateTime.to_iso8601(now),
                 DateTime.to_iso8601(now),
                 status,
                 DateTime.to_iso8601(now),
                 status,
                 status,
                 id,
                 runner_id
               ]
             ),
           {:ok, stopped} <- lookup_row(state.conn, id) do
        _ = prune(state.conn, state.max_terminal_rows)
        {:ok, stopped}
      else
        false -> {:error, {:invalid_staged_plan_terminal_status, status}}
        error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:cancel, id, cancelled_by, reason, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    cancelled_by = String.trim(cancelled_by)
    reason = String.trim(reason)
    _ = expire_due(state.conn, now)

    reply =
      with :ok <- validate_text(:cancelled_by, cancelled_by),
           :ok <- validate_text(:cancellation_reason, reason),
           {:ok, current} <- lookup_row(state.conn, id),
           :ok <- cancel_or_request(state.conn, current, cancelled_by, reason, now),
           {:ok, cancelled} <- lookup_row(state.conn, id) do
        publish(state.event_bus, %{
          type: :staged_plan_changed,
          plan_id: id,
          status: cancelled.status,
          cancellation_requested: cancelled.status == "running"
        })

        if cancelled.status == "cancelled", do: prune(state.conn, state.max_terminal_rows)
        {:ok, cancelled}
      end

    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.conn)

  def migrate(conn) do
    with :ok <-
           Sqlite3.execute(conn, """
           PRAGMA journal_mode = WAL;
           PRAGMA synchronous = NORMAL;

           CREATE TABLE IF NOT EXISTS home_staged_plans (
             id TEXT PRIMARY KEY,
             goal TEXT,
             status TEXT NOT NULL,
             plan_json TEXT NOT NULL,
             owner TEXT NOT NULL,
             source TEXT NOT NULL,
             reason TEXT NOT NULL,
             prepared_at TEXT NOT NULL,
             expires_at TEXT NOT NULL,
             inserted_at TEXT NOT NULL,
             updated_at TEXT NOT NULL,
             cancelled_at TEXT,
             cancelled_by TEXT,
             cancellation_reason TEXT,
             expired_at TEXT,
             runner_id TEXT,
             current_stage INTEGER NOT NULL DEFAULT 0,
             stage_results_json TEXT NOT NULL DEFAULT '[]',
             started_at TEXT,
             completed_at TEXT,
             final_result_json TEXT,
             waiting_since TEXT,
             next_evaluation_at TEXT,
             waiting_kind TEXT,
             observation_wakeup_at TEXT,
             observation_wakeup_count INTEGER NOT NULL DEFAULT 0,
             cancellation_requested_at TEXT,
             cancellation_requested_by TEXT,
             cancellation_request_reason TEXT
           );

           CREATE INDEX IF NOT EXISTS home_staged_plans_status_expiry_idx
             ON home_staged_plans(status, expires_at);
           CREATE INDEX IF NOT EXISTS home_staged_plans_updated_idx
             ON home_staged_plans(updated_at DESC);

           CREATE TABLE IF NOT EXISTS home_staged_plan_run_events (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             plan_id TEXT NOT NULL,
             event_type TEXT NOT NULL,
             details_json TEXT NOT NULL,
             recorded_at TEXT NOT NULL
           );

           CREATE INDEX IF NOT EXISTS home_staged_plan_run_events_plan_idx
             ON home_staged_plan_run_events(plan_id, id DESC);
           """),
         :ok <- ensure_column(conn, "runner_id", "TEXT"),
         :ok <- ensure_column(conn, "current_stage", "INTEGER NOT NULL DEFAULT 0"),
         :ok <- ensure_column(conn, "stage_results_json", "TEXT NOT NULL DEFAULT '[]'"),
         :ok <- ensure_column(conn, "started_at", "TEXT"),
         :ok <- ensure_column(conn, "completed_at", "TEXT"),
         :ok <- ensure_column(conn, "final_result_json", "TEXT"),
         :ok <- ensure_column(conn, "waiting_since", "TEXT"),
         :ok <- ensure_column(conn, "next_evaluation_at", "TEXT"),
         :ok <- ensure_column(conn, "waiting_kind", "TEXT"),
         :ok <- ensure_column(conn, "observation_wakeup_at", "TEXT"),
         :ok <- ensure_column(conn, "observation_wakeup_count", "INTEGER NOT NULL DEFAULT 0"),
         :ok <- ensure_column(conn, "cancellation_requested_at", "TEXT"),
         :ok <- ensure_column(conn, "cancellation_requested_by", "TEXT"),
         :ok <- ensure_column(conn, "cancellation_request_reason", "TEXT") do
      :ok
    end
  end

  defp persist_plan(state, plan, owner, source, reason, now) do
    public = Zaik.Home.StagedPlan.public(plan)
    encoded = Jason.encode!(public)

    case lookup_row(state.conn, plan.id) do
      {:error, :not_found} ->
        case execute(
               state.conn,
               """
               INSERT INTO home_staged_plans
                 (id, goal, status, plan_json, owner, source, reason, prepared_at,
                  expires_at, inserted_at, updated_at)
               VALUES (?, ?, 'prepared', ?, ?, ?, ?, ?, ?, ?, ?)
               """,
               [
                 plan.id,
                 plan.goal,
                 encoded,
                 owner,
                 source,
                 reason,
                 DateTime.to_iso8601(plan.prepared_at),
                 DateTime.to_iso8601(plan.expires_at),
                 DateTime.to_iso8601(now),
                 DateTime.to_iso8601(now)
               ]
             ) do
          :ok ->
            publish(state.event_bus, %{
              type: :staged_plan_changed,
              plan_id: plan.id,
              status: "prepared"
            })

            lookup_row(state.conn, plan.id)

          error ->
            error
        end

      {:ok, existing} ->
        {:ok, Map.put(existing, :duplicate, true)}
    end
  end

  defp expire_due(conn, now) do
    now = DateTime.to_iso8601(now)

    execute(
      conn,
      """
      UPDATE home_staged_plans
      SET status = 'expired', expired_at = ?, updated_at = ?, next_evaluation_at = NULL,
          waiting_kind = NULL
      WHERE status IN ('prepared', 'waiting', 'running') AND julianday(expires_at) <= julianday(?)
      """,
      [now, now, now]
    )
  end

  defp prune(_conn, maximum) when not is_integer(maximum) or maximum < 1, do: :ok

  defp prune(conn, maximum) do
    execute(
      conn,
      """
      DELETE FROM home_staged_plans
      WHERE status NOT IN ('prepared', 'waiting', 'running') AND id NOT IN (
        SELECT id FROM home_staged_plans WHERE status NOT IN ('prepared', 'waiting', 'running')
        ORDER BY julianday(updated_at) DESC, id DESC LIMIT ?
      )
      """,
      [maximum]
    )
  end

  defp prune_run_events(_conn, maximum) when not is_integer(maximum) or maximum < 1, do: :ok

  defp prune_run_events(conn, maximum) do
    execute(
      conn,
      """
      DELETE FROM home_staged_plan_run_events
      WHERE id NOT IN (
        SELECT id FROM home_staged_plan_run_events ORDER BY id DESC LIMIT ?
      )
      """,
      [maximum]
    )
  end

  defp decode_run_event([id, plan_id, event_type, details_json, recorded_at]) do
    %{
      id: id,
      plan_id: plan_id,
      event_type: event_type,
      details: Jason.decode!(details_json),
      recorded_at: recorded_at
    }
  end

  defp lookup_row(conn, id) do
    case query(conn, select_sql("WHERE id = ? LIMIT 1"), [id]) do
      [row] -> {:ok, decode(row)}
      [] -> {:error, :not_found}
    end
  end

  defp select_sql(suffix) do
    """
    SELECT id, goal, status, plan_json, owner, source, reason, prepared_at,
           expires_at, inserted_at, updated_at, cancelled_at, cancelled_by,
           cancellation_reason, expired_at, runner_id, current_stage,
           stage_results_json, started_at, completed_at, final_result_json,
           waiting_since, next_evaluation_at, waiting_kind, observation_wakeup_at,
           observation_wakeup_count, cancellation_requested_at,
           cancellation_requested_by, cancellation_request_reason
    FROM home_staged_plans #{suffix}
    """
  end

  defp decode([
         id,
         goal,
         status,
         plan_json,
         owner,
         source,
         reason,
         prepared_at,
         expires_at,
         inserted_at,
         updated_at,
         cancelled_at,
         cancelled_by,
         cancellation_reason,
         expired_at,
         runner_id,
         current_stage,
         stage_results_json,
         started_at,
         completed_at,
         final_result_json,
         waiting_since,
         next_evaluation_at,
         waiting_kind,
         observation_wakeup_at,
         observation_wakeup_count,
         cancellation_requested_at,
         cancellation_requested_by,
         cancellation_request_reason
       ]) do
    %{
      id: id,
      goal: goal,
      status: status,
      plan: Jason.decode!(plan_json),
      owner: owner,
      source: source,
      reason: reason,
      prepared_at: prepared_at,
      expires_at: expires_at,
      inserted_at: inserted_at,
      updated_at: updated_at,
      cancelled_at: cancelled_at,
      cancelled_by: cancelled_by,
      cancellation_reason: cancellation_reason,
      expired_at: expired_at,
      runner_id: runner_id,
      current_stage: current_stage,
      stage_results: Jason.decode!(stage_results_json),
      started_at: started_at,
      completed_at: completed_at,
      final_result: decode_json(final_result_json),
      waiting_since: waiting_since,
      next_evaluation_at: next_evaluation_at,
      waiting_kind: waiting_kind,
      observation_wakeup_at: observation_wakeup_at,
      observation_wakeup_count: observation_wakeup_count,
      cancellation_requested_at: cancellation_requested_at,
      cancellation_requested_by: cancellation_requested_by,
      cancellation_request_reason: cancellation_request_reason
    }
  end

  defp validate_plan_lifetime(%{status: "prepared", expires_at: expires_at}, now) do
    if DateTime.after?(expires_at, now), do: :ok, else: {:error, :staged_plan_already_expired}
  end

  defp validate_plan_lifetime(_plan, _now), do: {:error, :invalid_staged_plan_status}
  defp validate_text(field, ""), do: {:error, {:invalid_staged_plan_metadata, field}}
  defp validate_text(_field, _value), do: :ok

  defp cancel_or_request(conn, %{status: status, id: id}, cancelled_by, reason, now)
       when status in ["prepared", "waiting"] do
    now = DateTime.to_iso8601(now)

    execute(
      conn,
      """
      UPDATE home_staged_plans
      SET status = 'cancelled', cancelled_at = ?, cancelled_by = ?,
          cancellation_reason = ?, updated_at = ?, next_evaluation_at = NULL,
          waiting_kind = NULL
      WHERE id = ? AND status IN ('prepared', 'waiting')
      """,
      [now, cancelled_by, reason, now, id]
    )
  end

  defp cancel_or_request(
         _conn,
         %{status: "running", cancellation_requested_at: requested_at},
         _cancelled_by,
         _reason,
         _now
       )
       when is_binary(requested_at),
       do: {:error, :staged_plan_cancellation_already_requested}

  defp cancel_or_request(conn, %{status: "running", id: id}, cancelled_by, reason, now) do
    now = DateTime.to_iso8601(now)

    execute(
      conn,
      """
      UPDATE home_staged_plans
      SET cancellation_requested_at = ?, cancellation_requested_by = ?,
          cancellation_request_reason = ?, updated_at = ?
      WHERE id = ? AND status = 'running' AND cancellation_requested_at IS NULL
      """,
      [now, cancelled_by, reason, now, id]
    )
  end

  defp cancel_or_request(_conn, plan, _cancelled_by, _reason, _now),
    do: {:error, {:staged_plan_not_cancellable, plan.status}}

  defp observation_wakeable(%{status: "waiting", waiting_since: waiting_since}, observed_at)
       when is_binary(waiting_since) do
    with {:ok, started_at, _offset} <- DateTime.from_iso8601(waiting_since) do
      if DateTime.before?(observed_at, started_at),
        do: {:error, :staged_plan_observation_before_wait},
        else: :ok
    else
      _ -> {:error, :invalid_staged_plan_wait_schedule}
    end
  end

  defp observation_wakeable(plan, _observed_at),
    do: {:error, {:staged_plan_not_waiting, plan.status}}

  defp claimable(%{status: "prepared"}, _runner_id, _now), do: :ok

  defp claimable(%{status: "waiting", next_evaluation_at: nil}, _runner_id, _now), do: :ok

  defp claimable(%{status: "waiting", next_evaluation_at: value}, _runner_id, now) do
    with {:ok, next_at, _offset} <- DateTime.from_iso8601(value) do
      if DateTime.before?(now, next_at) do
        {:error,
         {:staged_plan_wait_not_ready,
          %{next_evaluation_at: value, retry_after_seconds: DateTime.diff(next_at, now, :second)}}}
      else
        :ok
      end
    else
      _ -> {:error, :invalid_staged_plan_wait_schedule}
    end
  end

  defp claimable(%{status: "running", runner_id: runner_id}, runner_id, _now), do: :ok

  defp claimable(%{status: "running"}, _runner_id, _now),
    do: {:error, :staged_plan_already_running}

  defp claimable(plan, _runner_id, _now), do: {:error, {:staged_plan_not_runnable, plan.status}}

  defp checkpoint_results(results, result, "waiting") do
    stage_index = result["stage_index"]
    waiting_kind = result["waiting_kind"]

    case List.pop_at(results, -1) do
      {%{"stage_index" => ^stage_index, "waiting_kind" => ^waiting_kind}, remaining} ->
        remaining ++ [result]

      _ ->
        results ++ [result]
    end
  end

  defp checkpoint_results(results, result, _status), do: results ++ [result]

  defp wait_schedule("running", _current, _result, _now), do: {:ok, nil, nil, nil}

  defp wait_schedule("waiting", current, result, now) do
    wait = value(result, :wait, %{})
    poll_seconds = value(wait, :poll_interval_seconds, nil)
    waiting_kind = value(result, :waiting_kind, "condition") |> to_string()

    cond do
      waiting_kind not in ["condition", "verification"] ->
        {:error, :invalid_staged_plan_wait_kind}

      not is_integer(poll_seconds) or poll_seconds < 1 ->
        {:error, :invalid_staged_plan_wait_schedule}

      true ->
        waiting_since =
          if current.waiting_kind == waiting_kind and is_binary(current.waiting_since),
            do: current.waiting_since,
            else: DateTime.to_iso8601(now)

        next_evaluation_at = now |> DateTime.add(poll_seconds, :second) |> DateTime.to_iso8601()
        {:ok, waiting_since, next_evaluation_at, waiting_kind}
    end
  end

  defp owned_running_plan(%{status: "running", runner_id: runner_id}, runner_id), do: :ok

  defp owned_running_plan(%{status: "running"}, _runner_id),
    do: {:error, :staged_plan_runner_mismatch}

  defp owned_running_plan(plan, _runner_id), do: {:error, {:staged_plan_not_running, plan.status}}

  defp publish(event_bus, _event) when event_bus in [nil, false], do: :ok

  defp publish(event_bus, event) do
    if process_available?(event_bus), do: Zaik.Home.EventBus.publish(event, event_bus)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp process_available?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp process_available?(name) when is_atom(name), do: not is_nil(Process.whereis(name))
  defp process_available?(_), do: false

  defp ensure_column(conn, column, definition) do
    columns = query(conn, "PRAGMA table_info(home_staged_plans)", [])

    if Enum.any?(columns, fn [_cid, name | _rest] -> name == column end) do
      :ok
    else
      Sqlite3.execute(conn, "ALTER TABLE home_staged_plans ADD COLUMN #{column} #{definition}")
    end
  end

  defp stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when is_boolean(value) or is_nil(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp decode_json(nil), do: nil
  defp decode_json(value), do: Jason.decode!(value)

  defp query(conn, sql, params) do
    {:ok, statement} = Sqlite3.prepare(conn, sql)

    try do
      :ok = Sqlite3.bind(statement, params)
      {:ok, rows} = Sqlite3.fetch_all(conn, statement)
      rows
    after
      Sqlite3.release(conn, statement)
    end
  end

  defp execute(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        :ok = Sqlite3.bind(statement, params)

        case Sqlite3.step(conn, statement) do
          :done -> :ok
          {:row, _row} -> :ok
          :busy -> {:error, :busy}
          {:error, reason} -> {:error, reason}
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, to_string(key), default))
  defp expand_path(":memory:"), do: ":memory:"
  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)
end

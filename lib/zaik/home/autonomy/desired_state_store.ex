defmodule Zaik.Home.Autonomy.DesiredStateStore do
  @moduledoc """
  Durable lease ledger for desired states selected by arbitration.

  It stores inert semantic targets only. It cannot invoke an executor.
  """

  use GenServer
  alias Exqlite.Sqlite3

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put_new(server_opts, :name, __MODULE__))
  end

  def record(decision, server \\ __MODULE__) when is_map(decision),
    do: GenServer.call(server, {:record, decision})

  def active(scope \\ nil, opts \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:active, scope, opts})

  def recent(limit \\ 50, server \\ __MODULE__), do: GenServer.call(server, {:recent, limit})

  def history(scope, limit \\ 50, server \\ __MODULE__) when is_binary(scope),
    do: GenServer.call(server, {:history, scope, limit})

  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :db_path, Zaik.Home.HistoryStore.config().db_path) |> expand_path()
    unless path == ":memory:", do: path |> Path.dirname() |> File.mkdir_p!()

    with {:ok, conn} <- Sqlite3.open(path), :ok <- migrate(conn) do
      {:ok,
       %{
         conn: conn,
         clock: Keyword.get(opts, :clock),
         max_rows: Keyword.get(opts, :max_rows, 10_000)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:record, decision}, _from, state) do
    cooldown_blocked =
      decision
      |> get_in([:reconciliation, :blocked])
      |> List.wrap()
      |> Enum.filter(&(value(&1, :reason) == "policy_cooldown"))
      |> MapSet.new(fn blocked -> desired_key(value(blocked, :desired)) end)

    selected =
      decision
      |> get_in([:arbitration, :selected])
      |> List.wrap()
      |> Enum.reject(&(desired_key(&1) in cooldown_blocked))

    now = value(decision, :created_at) || Zaik.Time.now(state.clock)
    decision_id = to_string(value(decision, :id))

    reply =
      with :ok <- validate_selected(selected, decision) do
        Enum.reduce_while(selected, {:ok, []}, fn desired, {:ok, stored} ->
          case put_desired(state.conn, desired, decision, decision_id, now) do
            {:ok, row} -> {:cont, {:ok, [row | stored]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, rows} ->
            prune(state.conn, state.max_rows)
            {:ok, Enum.reverse(rows)}

          error ->
            error
        end
      end

    {:reply, reply, state}
  end

  def handle_call({:active, scope, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock)) |> format_time()
    {scope_sql, params} = if is_binary(scope), do: {"AND scope = ?", [scope]}, else: {"", []}

    rows =
      query(
        state.conn,
        select_sql(
          "WHERE status = 'active' AND julianday(expires_at) > julianday(?) #{scope_sql} ORDER BY priority DESC, confidence DESC, created_at DESC"
        ),
        [now] ++ params
      )

    {:reply, Enum.map(rows, &decode/1), state}
  end

  def handle_call({:recent, limit}, _from, state) do
    limit = bounded_limit(limit)

    {:reply,
     query(state.conn, select_sql("ORDER BY created_at DESC LIMIT ?"), [limit])
     |> Enum.map(&decode/1), state}
  end

  def handle_call({:history, scope, limit}, _from, state) do
    limit = bounded_limit(limit)

    {:reply,
     query(state.conn, select_sql("WHERE scope = ? ORDER BY created_at DESC LIMIT ?"), [
       scope,
       limit
     ])
     |> Enum.map(&decode/1), state}
  end

  def handle_call(:reset, _from, state),
    do: {:reply, Sqlite3.execute(state.conn, "DELETE FROM home_desired_states"), state}

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.conn)

  def migrate(conn) do
    with :ok <-
           Sqlite3.execute(conn, """
           PRAGMA journal_mode = WAL;
           PRAGMA synchronous = NORMAL;

           CREATE TABLE IF NOT EXISTS home_desired_states (
             id TEXT PRIMARY KEY,
             decision_id TEXT NOT NULL,
             snapshot_id TEXT NOT NULL,
             scope TEXT NOT NULL,
             entity_id TEXT NOT NULL,
             device TEXT NOT NULL,
             capability TEXT NOT NULL,
             target_json TEXT NOT NULL,
             source_id TEXT NOT NULL,
             source_version TEXT NOT NULL,
             priority_class TEXT NOT NULL,
             priority INTEGER NOT NULL,
             confidence REAL NOT NULL,
             evidence_json TEXT NOT NULL,
             reason TEXT NOT NULL,
             policy_fingerprint TEXT NOT NULL,
             status TEXT NOT NULL,
             created_at TEXT NOT NULL,
             expires_at TEXT NOT NULL,
             superseded_at TEXT
           );

           CREATE INDEX IF NOT EXISTS home_desired_states_active_idx
             ON home_desired_states(scope, entity_id, capability, status, expires_at);
           """) do
      ensure_reason_column(conn)
    end
  end

  defp validate_selected(selected, decision) do
    snapshot_id = value(decision, :snapshot_id)

    cond do
      not non_empty_string?(snapshot_id) ->
        {:error, :missing_decision_snapshot_id}

      true ->
        selected
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {desired, index}, :ok ->
          evidence = value(desired, :evidence)
          confidence = value(desired, :confidence)

          reason =
            cond do
              not is_map(evidence) ->
                :missing_evidence

              value(evidence, :snapshot_id) != snapshot_id ->
                :evidence_snapshot_mismatch

              not non_empty_string?(value(evidence, :confidence_source)) ->
                :missing_confidence_source

              not is_number(confidence) or confidence < 0 or confidence > 1 ->
                :invalid_confidence

              not non_empty_string?(value(desired, :reason)) ->
                :missing_reason

              true ->
                nil
            end

          if reason,
            do: {:halt, {:error, {:invalid_desired_state_provenance, index, reason}}},
            else: {:cont, :ok}
        end)
    end
  end

  defp put_desired(conn, desired, decision, decision_id, now) do
    id = desired_id(desired, decision_id)
    entity_id = to_string(value(desired, :entity_id))
    capability = to_string(value(desired, :capability))
    created_at = format_time(now)

    with :ok <-
           execute(
             conn,
             """
             UPDATE home_desired_states SET status = 'superseded', superseded_at = ?
             WHERE entity_id = ? AND capability = ? AND status = 'active' AND id != ?
             """,
             [created_at, entity_id, capability, id]
           ),
         :ok <-
           execute(
             conn,
             """
             INSERT INTO home_desired_states (
               id, decision_id, snapshot_id, scope, entity_id, device, capability,
               target_json, source_id, source_version, priority_class, priority,
               confidence, evidence_json, reason, policy_fingerprint, status, created_at, expires_at
             ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)
             ON CONFLICT(id) DO UPDATE SET
               decision_id = excluded.decision_id,
               snapshot_id = excluded.snapshot_id,
               confidence = excluded.confidence,
               evidence_json = excluded.evidence_json,
               reason = excluded.reason,
               policy_fingerprint = excluded.policy_fingerprint,
               status = 'active',
               created_at = CASE
                 WHEN home_desired_states.status = 'active'
                   AND julianday(home_desired_states.expires_at) > julianday(excluded.created_at)
                 THEN home_desired_states.created_at
                 ELSE excluded.created_at
               END,
               expires_at = excluded.expires_at,
               superseded_at = NULL
             """,
             [
               id,
               decision_id,
               to_string(value(decision, :snapshot_id)),
               scope(desired, decision),
               entity_id,
               to_string(value(desired, :device)),
               capability,
               Jason.encode!(value(desired, :target)),
               to_string(value(desired, :policy_id)),
               to_string(value(desired, :policy_version)),
               to_string(value(desired, :priority_class)),
               value(desired, :priority),
               value(desired, :confidence),
               Jason.encode!(value(desired, :evidence) || %{}),
               to_string(value(desired, :reason)),
               to_string(value(decision, :policy_fingerprint)),
               created_at,
               to_string(value(desired, :expires_at))
             ]
           ) do
      lookup(conn, id)
    end
  end

  defp lookup(conn, id) do
    case query(conn, select_sql("WHERE id = ? LIMIT 1"), [id]) do
      [row] -> {:ok, decode(row)}
      [] -> {:error, :not_found}
    end
  end

  defp scope(desired, decision) do
    area = decision |> get_in([:context, :areas]) |> List.wrap() |> List.first()
    value(desired, :scope) || area || "home"
  end

  defp desired_key(desired) do
    {value(desired, :policy_id), to_string(value(desired, :entity_id)),
     to_string(value(desired, :capability)), value(desired, :target)}
  end

  defp desired_id(desired, _decision_id) do
    desired_key(desired)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("desired_" <> String.slice(&1, 0, 24)))
  end

  defp select_sql(suffix) do
    """
    SELECT id, decision_id, snapshot_id, scope, entity_id, device, capability,
           target_json, source_id, source_version, priority_class, priority,
           confidence, evidence_json, reason, policy_fingerprint, status, created_at,
           expires_at, superseded_at
    FROM home_desired_states #{suffix}
    """
  end

  defp decode([
         id,
         decision_id,
         snapshot_id,
         scope,
         entity_id,
         device,
         capability,
         target,
         source_id,
         source_version,
         priority_class,
         priority,
         confidence,
         evidence,
         reason,
         policy_fingerprint,
         status,
         created_at,
         expires_at,
         superseded_at
       ]) do
    %{
      id: id,
      decision_id: decision_id,
      snapshot_id: snapshot_id,
      scope: scope,
      entity_id: entity_id,
      device: device,
      capability: capability,
      target: Jason.decode!(target),
      source_id: source_id,
      source_version: source_version,
      priority_class: priority_class,
      priority: priority,
      confidence: confidence,
      evidence: Jason.decode!(evidence),
      reason: reason,
      policy_fingerprint: policy_fingerprint,
      status: status,
      created_at: created_at,
      expires_at: expires_at,
      superseded_at: superseded_at
    }
  end

  defp ensure_reason_column(conn) do
    columns = query(conn, "PRAGMA table_info(home_desired_states)", [])

    if Enum.any?(columns, fn row -> Enum.at(row, 1) == "reason" end) do
      :ok
    else
      Sqlite3.execute(
        conn,
        "ALTER TABLE home_desired_states ADD COLUMN reason TEXT NOT NULL DEFAULT 'legacy_unrecorded'"
      )
    end
  end

  defp prune(_conn, max) when not is_integer(max) or max < 1, do: :ok

  defp prune(conn, max),
    do:
      execute(
        conn,
        "DELETE FROM home_desired_states WHERE id IN (SELECT id FROM home_desired_states ORDER BY created_at DESC LIMIT -1 OFFSET ?)",
        [max]
      )

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
          {:row, _} -> :ok
          :busy -> {:error, :busy}
          {:error, reason} -> {:error, reason}
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp bounded_limit(limit) when is_integer(limit), do: max(1, min(limit, 200))
  defp bounded_limit(_limit), do: 50

  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: value
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp expand_path(":memory:"), do: ":memory:"
  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)
end

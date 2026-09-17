defmodule Zaik.Home.Autonomy.DecisionStore do
  @moduledoc """
  Durable SQLite ledger for inert home-autonomy decisions.
  """

  use GenServer
  alias Exqlite.Sqlite3

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put_new(server_opts, :name, __MODULE__))
  end

  def record(decision, server \\ __MODULE__) when is_map(decision),
    do: GenServer.call(server, {:record, decision})

  def lookup(id, server \\ __MODULE__) when is_binary(id),
    do: GenServer.call(server, {:lookup, id})

  def recent(limit \\ 20, server \\ __MODULE__) when is_integer(limit),
    do: GenServer.call(server, {:recent, limit})

  def record_outcome(id, outcome, server \\ __MODULE__)
      when is_binary(id) and is_map(outcome),
      do: GenServer.call(server, {:record_outcome, id, outcome})

  def record_feedback(id, feedback, server \\ __MODULE__)
      when is_binary(id) and is_map(feedback),
      do: GenServer.call(server, {:record_feedback, id, feedback})

  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :db_path, Zaik.Home.HistoryStore.config().db_path) |> expand_path()
    unless path == ":memory:", do: path |> Path.dirname() |> File.mkdir_p!()

    with {:ok, conn} <- Sqlite3.open(path), :ok <- migrate(conn) do
      {:ok,
       %{
         conn: conn,
         max_rows: Keyword.get(opts, :max_rows, 10_000),
         clock: Keyword.get(opts, :clock)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:record, decision}, _from, state) do
    normalized = normalize(decision)

    params = [
      normalized.id,
      normalized.mode,
      normalized.query,
      normalized.snapshot_id,
      normalized.status,
      Jason.encode!(normalized.context),
      Jason.encode!(normalized.candidates),
      Jason.encode!(normalized.policy_modes),
      Jason.encode!(normalized.arbitration),
      Jason.encode!(normalized.reconciliation),
      Jason.encode!(normalized.conflict_locks),
      Jason.encode!(normalized.action_budget),
      Jason.encode!(normalized.outcomes),
      Jason.encode!(normalized.feedback),
      normalized.policy_fingerprint,
      normalized.created_at
    ]

    reply =
      execute(
        state.conn,
        """
        INSERT INTO home_autonomy_decisions (
          id, mode, query, snapshot_id, status, context_json, candidates_json,
          policy_modes_json, arbitration_json, reconciliation_json, conflict_locks_json,
          action_budget_json, outcomes_json, feedback_json, policy_fingerprint, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO NOTHING
        """,
        params
      )
      |> case do
        :ok ->
          case prune(state.conn, state.max_rows) do
            :ok -> {:ok, normalized}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:lookup, id}, _from, state) do
    rows = query(state.conn, select_sql("WHERE id = ? LIMIT 1"), [id])
    {:reply, one(rows), state}
  end

  def handle_call({:recent, limit}, _from, state) do
    limit = max(1, min(limit, 200))

    {:reply,
     state.conn
     |> query(select_sql("ORDER BY created_at DESC LIMIT ?"), [limit])
     |> Enum.map(&decode/1), state}
  end

  def handle_call({:record_outcome, id, outcome}, _from, state) do
    reply = append_entry(state, id, :outcomes, validate_outcome(outcome))
    {:reply, reply, state}
  end

  def handle_call({:record_feedback, id, feedback}, _from, state) do
    reply = append_entry(state, id, :feedback, validate_feedback(feedback))
    {:reply, reply, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, Sqlite3.execute(state.conn, "DELETE FROM home_autonomy_decisions"), state}
  end

  @impl true
  def terminate(_reason, state) do
    Sqlite3.close(state.conn)
    :ok
  end

  def migrate(conn) do
    with :ok <-
           Sqlite3.execute(conn, """
           PRAGMA journal_mode = WAL;
           PRAGMA synchronous = NORMAL;

           CREATE TABLE IF NOT EXISTS home_autonomy_decisions (
             id TEXT PRIMARY KEY,
             mode TEXT NOT NULL,
             query TEXT NOT NULL,
             snapshot_id TEXT NOT NULL,
             status TEXT NOT NULL,
             context_json TEXT NOT NULL,
             candidates_json TEXT NOT NULL,
             policy_modes_json TEXT NOT NULL DEFAULT '[]',
             arbitration_json TEXT NOT NULL,
             reconciliation_json TEXT NOT NULL,
             conflict_locks_json TEXT NOT NULL DEFAULT '{}',
             action_budget_json TEXT NOT NULL DEFAULT '{}',
             outcomes_json TEXT NOT NULL DEFAULT '[]',
             feedback_json TEXT NOT NULL DEFAULT '[]',
             policy_fingerprint TEXT NOT NULL,
             created_at TEXT NOT NULL
           );

           CREATE INDEX IF NOT EXISTS home_autonomy_decisions_created_idx
             ON home_autonomy_decisions(created_at DESC);
           """),
         :ok <- ensure_json_column(conn, "policy_modes_json", "[]"),
         :ok <- ensure_json_column(conn, "conflict_locks_json", "{}"),
         :ok <- ensure_json_column(conn, "action_budget_json", "{}"),
         :ok <- ensure_json_column(conn, "outcomes_json", "[]"),
         :ok <- ensure_json_column(conn, "feedback_json", "[]") do
      :ok
    end
  end

  defp select_sql(suffix) do
    """
    SELECT id, mode, query, snapshot_id, status, context_json, candidates_json,
           policy_modes_json, arbitration_json, reconciliation_json, conflict_locks_json,
           action_budget_json, outcomes_json, feedback_json, policy_fingerprint, created_at
    FROM home_autonomy_decisions
    #{suffix}
    """
  end

  defp normalize(decision) do
    %{
      id: to_string(value(decision, :id)),
      mode: to_string(value(decision, :mode)),
      query: to_string(value(decision, :query)),
      snapshot_id: to_string(value(decision, :snapshot_id)),
      status: to_string(value(decision, :status)),
      context: json_safe(value(decision, :context) || %{}),
      candidates: json_safe(value(decision, :candidates) || []),
      policy_modes: json_safe(value(decision, :policy_modes) || []),
      arbitration: json_safe(value(decision, :arbitration) || %{}),
      reconciliation: json_safe(value(decision, :reconciliation) || %{}),
      conflict_locks: json_safe(value(decision, :conflict_locks) || %{}),
      action_budget: json_safe(value(decision, :action_budget) || %{}),
      outcomes: json_safe(value(decision, :outcomes) || []),
      feedback: json_safe(value(decision, :feedback) || []),
      policy_fingerprint: to_string(value(decision, :policy_fingerprint)),
      created_at: format_time(value(decision, :created_at))
    }
  end

  defp decode([
         id,
         mode,
         query,
         snapshot_id,
         status,
         context,
         candidates,
         policy_modes,
         arbitration,
         reconciliation,
         conflict_locks,
         action_budget,
         outcomes,
         feedback,
         policy_fingerprint,
         created_at
       ]) do
    %{
      id: id,
      mode: mode,
      query: query,
      snapshot_id: snapshot_id,
      status: status,
      context: Jason.decode!(context),
      candidates: Jason.decode!(candidates),
      policy_modes: Jason.decode!(policy_modes),
      arbitration: Jason.decode!(arbitration),
      reconciliation: Jason.decode!(reconciliation),
      conflict_locks: Jason.decode!(conflict_locks),
      action_budget: Jason.decode!(action_budget),
      outcomes: Jason.decode!(outcomes),
      feedback: Jason.decode!(feedback),
      policy_fingerprint: policy_fingerprint,
      created_at: created_at
    }
  end

  defp append_entry(_state, _id, _field, {:error, _reason} = error), do: error

  defp append_entry(state, id, field, {:ok, entry}) do
    case query(state.conn, select_sql("WHERE id = ? LIMIT 1"), [id]) do
      [] ->
        {:error, :not_found}

      [row] ->
        decision = decode(row)
        recorded_at = Zaik.Time.now(state.clock) |> DateTime.to_iso8601()
        entry = entry |> Map.put_new("recorded_at", recorded_at) |> json_safe()
        entries = (Map.fetch!(decision, field) ++ [entry]) |> Enum.take(-100)
        column = if field == :outcomes, do: "outcomes_json", else: "feedback_json"

        case execute(
               state.conn,
               "UPDATE home_autonomy_decisions SET #{column} = ? WHERE id = ?",
               [Jason.encode!(entries), id]
             ) do
          :ok ->
            case query(state.conn, select_sql("WHERE id = ? LIMIT 1"), [id]) do
              [updated] -> {:ok, decode(updated)}
              [] -> {:error, :not_found}
            end

          error ->
            error
        end
    end
  end

  defp validate_outcome(outcome) do
    status = value(outcome, :status)

    if is_binary(status) and String.trim(status) != "" do
      {:ok,
       outcome
       |> Map.new(fn {key, nested} -> {to_string(key), nested} end)
       |> Map.put("status", String.trim(status))}
    else
      {:error, {:invalid_autonomy_outcome, :status}}
    end
  end

  defp validate_feedback(feedback) do
    rating = value(feedback, :rating)
    owner = value(feedback, :owner) || "operator"

    if rating in [-1, 0, 1] and is_binary(owner) and String.trim(owner) != "" do
      {:ok,
       feedback
       |> Map.new(fn {key, nested} -> {to_string(key), nested} end)
       |> Map.put("rating", rating)
       |> Map.put("owner", String.trim(owner))}
    else
      {:error, {:invalid_autonomy_feedback, :rating_or_owner}}
    end
  end

  defp ensure_json_column(conn, column, default) do
    columns = query(conn, "PRAGMA table_info(home_autonomy_decisions)", [])

    if Enum.any?(columns, fn [_cid, name | _rest] -> name == column end) do
      :ok
    else
      Sqlite3.execute(
        conn,
        "ALTER TABLE home_autonomy_decisions ADD COLUMN #{column} TEXT NOT NULL DEFAULT '#{default}'"
      )
    end
  end

  defp one([]), do: {:error, :not_found}
  defp one([row | _]), do: {:ok, decode(row)}

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

  defp prune(_conn, max_rows) when not is_integer(max_rows) or max_rows < 1, do: :ok

  defp prune(conn, max_rows) do
    execute(
      conn,
      """
      DELETE FROM home_autonomy_decisions
      WHERE id IN (
        SELECT id FROM home_autonomy_decisions
        ORDER BY created_at DESC
        LIMIT -1 OFFSET ?
      )
      """,
      [max_rows]
    )
  end

  defp execute(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        :ok = Sqlite3.bind(statement, params)

        case Sqlite3.step(conn, statement) do
          :done -> :ok
          {:row, _row} -> :ok
          {:error, reason} -> {:error, reason}
          :busy -> {:error, :busy}
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp json_safe(%_{} = struct), do: struct |> Map.from_struct() |> json_safe()

  defp json_safe(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()

  defp json_safe(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp json_safe(value), do: value

  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: value
  defp format_time(_value), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp expand_path(":memory:"), do: ":memory:"
  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)
end

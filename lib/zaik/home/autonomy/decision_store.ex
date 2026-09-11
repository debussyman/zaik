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

  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :db_path, Zaik.Home.HistoryStore.config().db_path) |> expand_path()
    unless path == ":memory:", do: path |> Path.dirname() |> File.mkdir_p!()

    with {:ok, conn} <- Sqlite3.open(path), :ok <- migrate(conn) do
      {:ok, %{conn: conn, max_rows: Keyword.get(opts, :max_rows, 10_000)}}
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
      Jason.encode!(normalized.arbitration),
      Jason.encode!(normalized.reconciliation),
      normalized.policy_fingerprint,
      normalized.created_at
    ]

    reply =
      execute(
        state.conn,
        """
        INSERT INTO home_autonomy_decisions (
          id, mode, query, snapshot_id, status, context_json, candidates_json,
          arbitration_json, reconciliation_json, policy_fingerprint, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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

  def handle_call(:reset, _from, state) do
    {:reply, Sqlite3.execute(state.conn, "DELETE FROM home_autonomy_decisions"), state}
  end

  @impl true
  def terminate(_reason, state) do
    Sqlite3.close(state.conn)
    :ok
  end

  def migrate(conn) do
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
      arbitration_json TEXT NOT NULL,
      reconciliation_json TEXT NOT NULL,
      policy_fingerprint TEXT NOT NULL,
      created_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS home_autonomy_decisions_created_idx
      ON home_autonomy_decisions(created_at DESC);
    """)
  end

  defp select_sql(suffix) do
    """
    SELECT id, mode, query, snapshot_id, status, context_json, candidates_json,
           arbitration_json, reconciliation_json, policy_fingerprint, created_at
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
      arbitration: json_safe(value(decision, :arbitration) || %{}),
      reconciliation: json_safe(value(decision, :reconciliation) || %{}),
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
         arbitration,
         reconciliation,
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
      arbitration: Jason.decode!(arbitration),
      reconciliation: Jason.decode!(reconciliation),
      policy_fingerprint: policy_fingerprint,
      created_at: created_at
    }
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

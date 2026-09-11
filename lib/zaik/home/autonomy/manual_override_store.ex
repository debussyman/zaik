defmodule Zaik.Home.Autonomy.ManualOverrideStore do
  @moduledoc """
  Durable, expiring manual-override leases that suppress background autonomy.

  Overrides are scoped to an area (or `home`), optionally limited to one
  capability, and always retain their owner, reason, and expiry.
  """

  use GenServer
  alias Exqlite.Sqlite3

  @max_ttl_seconds 7 * 24 * 60 * 60

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put_new(server_opts, :name, __MODULE__))
  end

  def create(scope, attrs \\ %{}, opts \\ [], server \\ __MODULE__)
      when is_binary(scope) and is_map(attrs) do
    GenServer.call(server, {:create, scope, attrs, opts})
  end

  def active(scope, opts \\ [], server \\ __MODULE__) when is_binary(scope),
    do: GenServer.call(server, {:active, scope, opts})

  def cancel(id, cancelled_by, opts \\ [], server \\ __MODULE__)
      when is_binary(id) and is_binary(cancelled_by),
      do: GenServer.call(server, {:cancel, id, cancelled_by, opts})

  def lookup(id, server \\ __MODULE__) when is_binary(id),
    do: GenServer.call(server, {:lookup, id})

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :db_path, Zaik.Home.HistoryStore.config().db_path) |> expand_path()
    unless path == ":memory:", do: path |> Path.dirname() |> File.mkdir_p!()

    with {:ok, conn} <- Sqlite3.open(path), :ok <- migrate(conn) do
      {:ok, %{conn: conn, clock: Keyword.get(opts, :clock)}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:create, scope, attrs, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    ttl = attrs |> value(:ttl_seconds, 3_600) |> normalize_ttl()
    owner = attrs |> value(:owner, "operator") |> to_string() |> String.trim()
    reason = attrs |> value(:reason, "manual action") |> to_string() |> String.trim()
    capability = normalize_optional(value(attrs, :capability))
    scope = normalize_scope(scope)

    with :ok <- validate_text(:scope, scope),
         :ok <- validate_text(:owner, owner),
         :ok <- validate_text(:reason, reason) do
      expires_at = DateTime.add(now, ttl, :second)
      id = lease_id(scope, capability, owner, now)

      params = [
        id,
        scope,
        capability,
        owner,
        reason,
        DateTime.to_iso8601(now),
        DateTime.to_iso8601(expires_at)
      ]

      case execute(
             state.conn,
             """
             INSERT INTO home_manual_overrides (
               id, scope, capability, owner, reason, status, created_at, expires_at
             ) VALUES (?, ?, ?, ?, ?, 'active', ?, ?)
             """,
             params
           ) do
        :ok -> {:reply, lookup_row(state.conn, id), state}
        error -> {:reply, error, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:active, scope, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock)) |> DateTime.to_iso8601()
    capability = normalize_optional(Keyword.get(opts, :capability))
    scope = normalize_scope(scope)

    sql = """
    SELECT id, scope, capability, owner, reason, status, created_at, expires_at,
           cancelled_at, cancelled_by
    FROM home_manual_overrides
    WHERE status = 'active' AND julianday(expires_at) > julianday(?)
      AND (scope = ? OR scope = 'home')
      AND (? IS NULL OR capability IS NULL OR capability = ?)
    ORDER BY created_at DESC
    """

    {:reply, query(state.conn, sql, [now, scope, capability, capability]) |> Enum.map(&decode/1),
     state}
  end

  def handle_call({:cancel, id, cancelled_by, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock)) |> DateTime.to_iso8601()

    with :ok <- validate_text(:cancelled_by, String.trim(cancelled_by)),
         :ok <-
           execute(
             state.conn,
             """
             UPDATE home_manual_overrides
             SET status = 'cancelled', cancelled_at = ?, cancelled_by = ?
             WHERE id = ? AND status = 'active'
             """,
             [now, cancelled_by, id]
           ) do
      {:reply, lookup_row(state.conn, id), state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:lookup, id}, _from, state), do: {:reply, lookup_row(state.conn, id), state}

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.conn)

  def migrate(conn) do
    Sqlite3.execute(conn, """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;

    CREATE TABLE IF NOT EXISTS home_manual_overrides (
      id TEXT PRIMARY KEY,
      scope TEXT NOT NULL,
      capability TEXT,
      owner TEXT NOT NULL,
      reason TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      cancelled_at TEXT,
      cancelled_by TEXT
    );

    CREATE INDEX IF NOT EXISTS home_manual_overrides_active_idx
      ON home_manual_overrides(scope, status, expires_at);
    """)
  end

  defp lookup_row(conn, id) do
    case query(
           conn,
           """
           SELECT id, scope, capability, owner, reason, status, created_at, expires_at,
                  cancelled_at, cancelled_by
           FROM home_manual_overrides WHERE id = ? LIMIT 1
           """,
           [id]
         ) do
      [row] -> {:ok, decode(row)}
      [] -> {:error, :not_found}
    end
  end

  defp decode([
         id,
         scope,
         capability,
         owner,
         reason,
         status,
         created_at,
         expires_at,
         cancelled_at,
         cancelled_by
       ]) do
    %{
      id: id,
      scope: scope,
      capability: capability,
      owner: owner,
      reason: reason,
      status: status,
      created_at: created_at,
      expires_at: expires_at,
      cancelled_at: cancelled_at,
      cancelled_by: cancelled_by
    }
  end

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

  defp lease_id(scope, capability, owner, now) do
    {scope, capability, owner, DateTime.to_iso8601(now), System.unique_integer([:positive])}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("override_" <> String.slice(&1, 0, 24)))
  end

  defp normalize_ttl(value) when is_integer(value), do: max(1, min(value, @max_ttl_seconds))
  defp normalize_ttl(_), do: 3_600
  defp normalize_scope(scope), do: scope |> String.trim() |> String.downcase()
  defp normalize_optional(nil), do: nil
  defp normalize_optional(""), do: nil
  defp normalize_optional(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp validate_text(field, ""), do: {:error, {:invalid_manual_override, field}}
  defp validate_text(_field, _value), do: :ok

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp expand_path(":memory:"), do: ":memory:"
  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)
end

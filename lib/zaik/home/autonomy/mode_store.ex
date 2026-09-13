defmodule Zaik.Home.Autonomy.ModeStore do
  @moduledoc """
  Durable, expiring household-mode leases used as typed policy evidence.

  Modes describe operator-approved context such as bedtime or privacy. They do
  not contain device commands and cannot invoke executors.
  """

  use GenServer
  alias Exqlite.Sqlite3

  @modes ["bedtime", "privacy"]
  @max_ttl_seconds 24 * 60 * 60

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put_new(server_opts, :name, __MODULE__))
  end

  def activate(scope, mode, attrs \\ %{}, opts \\ [], server \\ __MODULE__)
      when is_binary(scope) and is_map(attrs),
      do: GenServer.call(server, {:activate, scope, mode, attrs, opts})

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
      {:ok,
       %{
         conn: conn,
         clock: Keyword.get(opts, :clock),
         event_bus: Keyword.get(opts, :event_bus, Zaik.Home.EventBus)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:activate, scope, mode, attrs, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    scope = normalize(scope)
    mode = normalize(mode)
    owner = attrs |> value(:owner, "operator") |> to_string() |> String.trim()
    reason = attrs |> value(:reason, "operator mode") |> to_string() |> String.trim()
    source = attrs |> value(:source, "operator") |> to_string() |> String.trim()
    ttl = attrs |> value(:ttl_seconds, 8 * 60 * 60) |> normalize_ttl()

    with :ok <- validate_scope(scope),
         :ok <- validate_mode(mode),
         :ok <- validate_text(:owner, owner),
         :ok <- validate_text(:reason, reason),
         :ok <- validate_text(:source, source),
         :ok <- supersede_mode(state.conn, scope, mode, now),
         id = lease_id(scope, mode, owner, now),
         :ok <-
           execute(
             state.conn,
             """
             INSERT INTO home_mode_leases
               (id, scope, mode, owner, reason, source, status, created_at, expires_at)
             VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?)
             """,
             [
               id,
               scope,
               mode,
               owner,
               reason,
               source,
               DateTime.to_iso8601(now),
               now |> DateTime.add(ttl, :second) |> DateTime.to_iso8601()
             ]
           ),
         {:ok, lease} <- lookup_row(state.conn, id) do
      publish(state.event_bus, %{
        type: :home_mode_changed,
        area: scope,
        mode: mode,
        status: "active"
      })

      {:reply, {:ok, lease}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:active, scope, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock)) |> DateTime.to_iso8601()
    scope = normalize(scope)

    rows =
      query(
        state.conn,
        select_sql(
          "WHERE status = 'active' AND julianday(expires_at) > julianday(?) AND (scope = ? OR scope = 'home') ORDER BY created_at DESC"
        ),
        [now, scope]
      )

    {:reply, Enum.map(rows, &decode/1), state}
  end

  def handle_call({:cancel, id, cancelled_by, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock)) |> DateTime.to_iso8601()
    cancelled_by = String.trim(cancelled_by)

    with :ok <- validate_text(:cancelled_by, cancelled_by),
         {:ok, current} <- lookup_row(state.conn, id),
         :ok <- active_lease(current),
         :ok <-
           execute(
             state.conn,
             """
             UPDATE home_mode_leases
             SET status = 'cancelled', cancelled_at = ?, cancelled_by = ?
             WHERE id = ? AND status = 'active'
             """,
             [now, cancelled_by, id]
           ),
         {:ok, lease} <- lookup_row(state.conn, id) do
      publish(state.event_bus, %{
        type: :home_mode_changed,
        area: current.scope,
        mode: current.mode,
        status: "cancelled"
      })

      {:reply, {:ok, lease}, state}
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

    CREATE TABLE IF NOT EXISTS home_mode_leases (
      id TEXT PRIMARY KEY,
      scope TEXT NOT NULL,
      mode TEXT NOT NULL,
      owner TEXT NOT NULL,
      reason TEXT NOT NULL,
      source TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      expires_at TEXT NOT NULL,
      cancelled_at TEXT,
      cancelled_by TEXT,
      superseded_at TEXT
    );

    CREATE INDEX IF NOT EXISTS home_mode_leases_active_idx
      ON home_mode_leases(scope, mode, status, expires_at);
    """)
  end

  defp supersede_mode(conn, scope, mode, now) do
    execute(
      conn,
      """
      UPDATE home_mode_leases SET status = 'superseded', superseded_at = ?
      WHERE scope = ? AND mode = ? AND status = 'active'
      """,
      [DateTime.to_iso8601(now), scope, mode]
    )
  end

  defp lookup_row(conn, id) do
    case query(conn, select_sql("WHERE id = ? LIMIT 1"), [id]) do
      [row] -> {:ok, decode(row)}
      [] -> {:error, :not_found}
    end
  end

  defp select_sql(suffix) do
    """
    SELECT id, scope, mode, owner, reason, source, status, created_at, expires_at,
           cancelled_at, cancelled_by, superseded_at
    FROM home_mode_leases #{suffix}
    """
  end

  defp decode([
         id,
         scope,
         mode,
         owner,
         reason,
         source,
         status,
         created_at,
         expires_at,
         cancelled_at,
         cancelled_by,
         superseded_at
       ]) do
    %{
      id: id,
      scope: scope,
      mode: mode,
      owner: owner,
      reason: reason,
      source: source,
      status: status,
      created_at: created_at,
      expires_at: expires_at,
      cancelled_at: cancelled_at,
      cancelled_by: cancelled_by,
      superseded_at: superseded_at
    }
  end

  defp publish(event_bus, _event) when event_bus in [nil, false], do: :ok

  defp publish(event_bus, event) do
    if process_available?(event_bus), do: Zaik.Home.EventBus.publish(event, event_bus)
    :ok
  end

  defp process_available?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp process_available?(name) when is_atom(name), do: not is_nil(Process.whereis(name))
  defp process_available?(_), do: false

  defp active_lease(%{status: "active"}), do: :ok
  defp active_lease(lease), do: {:error, {:home_mode_not_active, lease.id}}

  defp validate_mode(mode) when mode in @modes, do: :ok
  defp validate_mode(mode), do: {:error, {:unsupported_home_mode, mode}}
  defp validate_scope(""), do: {:error, {:invalid_home_mode, :scope}}
  defp validate_scope(_scope), do: :ok
  defp validate_text(field, ""), do: {:error, {:invalid_home_mode, field}}
  defp validate_text(_field, _text), do: :ok
  defp normalize_ttl(value) when is_integer(value), do: max(1, min(value, @max_ttl_seconds))
  defp normalize_ttl(_value), do: 8 * 60 * 60
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp lease_id(scope, mode, owner, now) do
    {scope, mode, owner, DateTime.to_iso8601(now), System.unique_integer([:positive])}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("mode_" <> String.slice(&1, 0, 24)))
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

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, to_string(key), default))
  defp expand_path(":memory:"), do: ":memory:"
  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)
end

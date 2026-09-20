defmodule Zaik.Home.Autonomy.RolloutStore do
  @moduledoc """
  Durable operator approvals and rollback for physical-trial eligibility.

  Approved records are evidence only. This store has no executor and does not
  alter autonomy modes; `:canary` and `:active` remain rejected elsewhere.
  """

  use GenServer
  alias Exqlite.Sqlite3

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put_new(server_opts, :name, __MODULE__))
  end

  def approve(report, approved_by, reason, opts \\ [], server \\ __MODULE__)
      when is_map(report) and is_binary(approved_by) and is_binary(reason),
      do: GenServer.call(server, {:approve, report, approved_by, reason, opts})

  def get(id, server \\ __MODULE__) when is_binary(id), do: GenServer.call(server, {:get, id})
  def active(scope \\ nil, server \\ __MODULE__), do: GenServer.call(server, {:active, scope})
  def recent(limit \\ 20, server \\ __MODULE__), do: GenServer.call(server, {:recent, limit})

  def rollback(id, rolled_back_by, reason, opts \\ [], server \\ __MODULE__)
      when is_binary(id) and is_binary(rolled_back_by) and is_binary(reason),
      do: GenServer.call(server, {:rollback, id, rolled_back_by, reason, opts})

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
  def handle_call({:approve, report, approved_by, reason, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    approved_by = String.trim(approved_by)
    reason = String.trim(reason)

    reply =
      with :ok <- Zaik.Home.Autonomy.RolloutGate.validate(report),
           :ok <- validate_text(:approved_by, approved_by),
           :ok <- validate_text(:reason, reason),
           :ok <- current_policy(report),
           id <- rollout_id(report, approved_by, now),
           :ok <- persist_approval(state.conn, id, report, approved_by, reason, now),
           {:ok, record} <- lookup(state.conn, id) do
        {:ok, record}
      end

    {:reply, reply, state}
  end

  def handle_call({:get, id}, _from, state) do
    {:reply, lookup(state.conn, id), state}
  end

  def handle_call({:active, scope}, _from, state) do
    {where, params} =
      case normalize_optional(scope) do
        nil -> {"WHERE status = 'approved'", []}
        scope -> {"WHERE status = 'approved' AND scope = ?", [scope]}
      end

    records = query(state.conn, select_sql("#{where} ORDER BY approved_at DESC"), params)
    {:reply, Enum.map(records, &decode/1), state}
  end

  def handle_call({:recent, limit}, _from, state) do
    limit = if is_integer(limit), do: max(1, min(limit, 200)), else: 20
    records = query(state.conn, select_sql("ORDER BY approved_at DESC LIMIT ?"), [limit])
    {:reply, Enum.map(records, &decode/1), state}
  end

  def handle_call({:rollback, id, rolled_back_by, reason, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock)) |> DateTime.to_iso8601()
    rolled_back_by = String.trim(rolled_back_by)
    reason = String.trim(reason)

    reply =
      with :ok <- validate_text(:rolled_back_by, rolled_back_by),
           :ok <- validate_text(:reason, reason),
           {:ok, %{status: "approved"}} <- lookup(state.conn, id),
           :ok <-
             execute(
               state.conn,
               "UPDATE home_autonomy_rollouts SET status = 'rolled_back', rolled_back_at = ?, rolled_back_by = ?, rollback_reason = ? WHERE id = ? AND status = 'approved'",
               [now, rolled_back_by, reason, id]
             ),
           {:ok, record} <- lookup(state.conn, id) do
        {:ok, record}
      else
        {:ok, _record} -> {:error, :rollout_not_active}
        error -> error
      end

    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.conn)

  defp migrate(conn) do
    Sqlite3.execute(conn, """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;

    CREATE TABLE IF NOT EXISTS home_autonomy_rollouts (
      id TEXT PRIMARY KEY,
      policy_id TEXT NOT NULL,
      policy_version TEXT NOT NULL,
      scope TEXT NOT NULL,
      report_id TEXT NOT NULL,
      report_json TEXT NOT NULL,
      approved_by TEXT NOT NULL,
      reason TEXT NOT NULL,
      status TEXT NOT NULL,
      approved_at TEXT NOT NULL,
      superseded_at TEXT,
      rolled_back_at TEXT,
      rolled_back_by TEXT,
      rollback_reason TEXT
    );

    CREATE UNIQUE INDEX IF NOT EXISTS home_autonomy_rollouts_active_idx
      ON home_autonomy_rollouts(policy_id, scope)
      WHERE status = 'approved';
    CREATE INDEX IF NOT EXISTS home_autonomy_rollouts_history_idx
      ON home_autonomy_rollouts(approved_at DESC);
    """)
  end

  defp current_policy(report) do
    policy_id = to_string(value(report, :policy_id))

    with {:ok, %{descriptor: descriptor}} <- Zaik.Home.Policies.Registry.fetch(policy_id),
         expected <- descriptor_fingerprint(descriptor),
         ^expected <- value(report, :policy_descriptor_fingerprint),
         current_registry <- Zaik.Home.Policies.Registry.fingerprint(),
         ^current_registry <- value(report, :policy_registry_fingerprint) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :rollout_policy_changed}
    end
  end

  defp persist_approval(conn, id, report, approved_by, reason, now) do
    with :ok <- execute(conn, "BEGIN IMMEDIATE", []),
         :ok <- supersede(conn, report, now),
         :ok <- insert(conn, id, report, approved_by, reason, now),
         :ok <- execute(conn, "COMMIT", []) do
      :ok
    else
      error ->
        _ = execute(conn, "ROLLBACK", [])
        error
    end
  end

  defp supersede(conn, report, now) do
    execute(
      conn,
      "UPDATE home_autonomy_rollouts SET status = 'superseded', superseded_at = ? WHERE policy_id = ? AND scope = ? AND status = 'approved'",
      [
        DateTime.to_iso8601(now),
        to_string(value(report, :policy_id)),
        to_string(value(report, :scope))
      ]
    )
  end

  defp insert(conn, id, report, approved_by, reason, now) do
    execute(
      conn,
      """
      INSERT INTO home_autonomy_rollouts
        (id, policy_id, policy_version, scope, report_id, report_json,
         approved_by, reason, status, approved_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'approved', ?)
      """,
      [
        id,
        to_string(value(report, :policy_id)),
        to_string(value(report, :policy_version)),
        to_string(value(report, :scope)),
        to_string(value(report, :report_id)),
        Jason.encode!(report),
        approved_by,
        reason,
        DateTime.to_iso8601(now)
      ]
    )
  end

  defp rollout_id(report, approved_by, now) do
    {value(report, :report_id), approved_by, DateTime.to_iso8601(now)}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("rollout_" <> String.slice(&1, 0, 24)))
  end

  defp lookup(conn, id) do
    case query(conn, select_sql("WHERE id = ? LIMIT 1"), [id]) do
      [row] -> {:ok, decode(row)}
      [] -> {:error, :not_found}
    end
  end

  defp select_sql(suffix) do
    """
    SELECT id, policy_id, policy_version, scope, report_id, report_json,
           approved_by, reason, status, approved_at, superseded_at,
           rolled_back_at, rolled_back_by, rollback_reason
    FROM home_autonomy_rollouts
    #{suffix}
    """
  end

  defp decode([
         id,
         policy_id,
         policy_version,
         scope,
         report_id,
         report_json,
         approved_by,
         reason,
         status,
         approved_at,
         superseded_at,
         rolled_back_at,
         rolled_back_by,
         rollback_reason
       ]) do
    %{
      id: id,
      policy_id: policy_id,
      policy_version: policy_version,
      scope: scope,
      report_id: report_id,
      report: Jason.decode!(report_json),
      approved_by: approved_by,
      reason: reason,
      status: status,
      approved_at: approved_at,
      superseded_at: superseded_at,
      rolled_back_at: rolled_back_at,
      rolled_back_by: rolled_back_by,
      rollback_reason: rollback_reason,
      execution_enabled: false
    }
  end

  defp descriptor_fingerprint(descriptor) do
    descriptor
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp validate_text(field, value) do
    if value != "" and byte_size(value) <= 500 and not String.contains?(value, ["\r", "\n"]),
      do: :ok,
      else: {:error, {:invalid_rollout_field, field}}
  end

  defp normalize_optional(nil), do: nil
  defp normalize_optional(value), do: value |> to_string() |> String.trim()
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp execute(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        :ok = Sqlite3.bind(statement, params)

        case Sqlite3.step(conn, statement) do
          :done -> :ok
          {:error, reason} -> {:error, reason}
          :busy -> {:error, :busy}
          {:row, _row} -> :ok
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
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

  defp expand_path(":memory:"), do: ":memory:"
  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)
end

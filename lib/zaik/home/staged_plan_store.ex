defmodule Zaik.Home.StagedPlanStore do
  @moduledoc """
  Durable, audited storage for inert preflighted staged plans.

  Stored plans cannot execute. This store supports inspection, expiry, and
  explicit exact-ID cancellation so a future supervised coordinator has a
  durable lifecycle boundary instead of recovering from process memory.
  """

  use GenServer
  alias Exqlite.Sqlite3

  @default_max_terminal_rows 10_000

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

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :db_path, Zaik.Home.HistoryStore.config().db_path) |> expand_path()
    unless path == ":memory:", do: path |> Path.dirname() |> File.mkdir_p!()

    with {:ok, conn} <- Sqlite3.open(path), :ok <- migrate(conn) do
      state = %{
        conn: conn,
        clock: Keyword.get(opts, :clock),
        event_bus: Keyword.get(opts, :event_bus, Zaik.Home.EventBus),
        max_terminal_rows: Keyword.get(opts, :max_terminal_rows, @default_max_terminal_rows)
      }

      _ = expire_due(conn, Zaik.Time.now(state.clock))
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
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
        select_sql("WHERE status = 'prepared' ORDER BY julianday(prepared_at), id"),
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

  def handle_call({:cancel, id, cancelled_by, reason, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    cancelled_by = String.trim(cancelled_by)
    reason = String.trim(reason)
    _ = expire_due(state.conn, now)

    reply =
      with :ok <- validate_text(:cancelled_by, cancelled_by),
           :ok <- validate_text(:cancellation_reason, reason),
           {:ok, current} <- lookup_row(state.conn, id),
           :ok <- cancellable(current),
           :ok <-
             execute(
               state.conn,
               """
               UPDATE home_staged_plans
               SET status = 'cancelled', cancelled_at = ?, cancelled_by = ?,
                   cancellation_reason = ?, updated_at = ?
               WHERE id = ? AND status = 'prepared'
               """,
               [
                 DateTime.to_iso8601(now),
                 cancelled_by,
                 reason,
                 DateTime.to_iso8601(now),
                 id
               ]
             ),
           {:ok, cancelled} <- lookup_row(state.conn, id) do
        publish(state.event_bus, %{
          type: :staged_plan_changed,
          plan_id: id,
          status: "cancelled"
        })

        _ = prune(state.conn, state.max_terminal_rows)
        {:ok, cancelled}
      end

    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.conn)

  def migrate(conn) do
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
      expired_at TEXT
    );

    CREATE INDEX IF NOT EXISTS home_staged_plans_status_expiry_idx
      ON home_staged_plans(status, expires_at);
    CREATE INDEX IF NOT EXISTS home_staged_plans_updated_idx
      ON home_staged_plans(updated_at DESC);
    """)
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
      SET status = 'expired', expired_at = ?, updated_at = ?
      WHERE status = 'prepared' AND julianday(expires_at) <= julianday(?)
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
      WHERE status != 'prepared' AND id NOT IN (
        SELECT id FROM home_staged_plans WHERE status != 'prepared'
        ORDER BY julianday(updated_at) DESC, id DESC LIMIT ?
      )
      """,
      [maximum]
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
    SELECT id, goal, status, plan_json, owner, source, reason, prepared_at,
           expires_at, inserted_at, updated_at, cancelled_at, cancelled_by,
           cancellation_reason, expired_at
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
         expired_at
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
      expired_at: expired_at
    }
  end

  defp validate_plan_lifetime(%{status: "prepared", expires_at: expires_at}, now) do
    if DateTime.after?(expires_at, now), do: :ok, else: {:error, :staged_plan_already_expired}
  end

  defp validate_plan_lifetime(_plan, _now), do: {:error, :invalid_staged_plan_status}
  defp validate_text(field, ""), do: {:error, {:invalid_staged_plan_metadata, field}}
  defp validate_text(_field, _value), do: :ok
  defp cancellable(%{status: "prepared"}), do: :ok
  defp cancellable(plan), do: {:error, {:staged_plan_not_cancellable, plan.status}}

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

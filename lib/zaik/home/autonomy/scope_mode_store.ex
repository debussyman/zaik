defmodule Zaik.Home.Autonomy.ScopeModeStore do
  @moduledoc """
  Durable operator configuration for home, area, and policy autonomy modes.

  Only `off`, `shadow`, and `advisory` are accepted. Rules are context for the
  inert autonomy evaluator; this store cannot execute actions. Resolution is
  deterministic and returns the exact rule responsible for the effective mode.
  """

  use GenServer
  alias Exqlite.Sqlite3

  @modes ~w(off shadow advisory)

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put_new(server_opts, :name, __MODULE__))
  end

  def configure(scope, mode, attrs \\ %{}, opts \\ [], server \\ __MODULE__)
      when is_binary(scope) and is_map(attrs),
      do: GenServer.call(server, {:configure, scope, mode, attrs, opts})

  def active(scope \\ nil, opts \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:active, scope, opts})

  def remove(id, removed_by, opts \\ [], server \\ __MODULE__)
      when is_binary(id) and is_binary(removed_by),
      do: GenServer.call(server, {:remove, id, removed_by, opts})

  def effective(scope, policy_id, fallback_mode, opts \\ [], server \\ __MODULE__)
      when is_binary(scope) and is_binary(policy_id),
      do: GenServer.call(server, {:effective, scope, policy_id, fallback_mode, opts})

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
  def handle_call({:configure, scope, mode, attrs, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    scope = normalize(scope)
    mode = normalize(mode)
    policy_id = normalize_optional(value(attrs, :policy_id))
    changed_by = attrs |> value(:changed_by, "operator") |> to_string() |> String.trim()
    reason = attrs |> value(:reason, "operator configuration") |> to_string() |> String.trim()

    id = rule_id(scope, policy_id, mode, changed_by, now)

    with :ok <- validate_scope(scope),
         :ok <- validate_mode(mode),
         :ok <- validate_policy(policy_id, opts),
         :ok <- validate_text(:changed_by, changed_by),
         :ok <- validate_text(:reason, reason),
         :ok <- persist_rule(state.conn, id, scope, policy_id, mode, changed_by, reason, now),
         {:ok, rule} <- lookup_row(state.conn, id) do
      publish(state.event_bus, %{
        type: :autonomy_scope_mode_changed,
        area: scope,
        policy_id: policy_id,
        mode: mode,
        status: "active"
      })

      {:reply, {:ok, rule}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:active, scope, _opts}, _from, state) do
    {where, params} =
      case normalize_optional(scope) do
        nil -> {"WHERE status = 'active'", []}
        scope -> {"WHERE status = 'active' AND scope = ?", [scope]}
      end

    rows =
      query(
        state.conn,
        select_sql("#{where} ORDER BY scope, policy_id, created_at DESC"),
        params
      )

    {:reply, Enum.map(rows, &decode/1), state}
  end

  def handle_call({:remove, id, removed_by, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock)) |> DateTime.to_iso8601()
    removed_by = String.trim(removed_by)

    with :ok <- validate_text(:removed_by, removed_by),
         {:ok, current} <- lookup_row(state.conn, id),
         :ok <- active_rule(current),
         :ok <-
           execute(
             state.conn,
             """
             UPDATE home_autonomy_scope_modes
             SET status = 'removed', removed_at = ?, removed_by = ?
             WHERE id = ? AND status = 'active'
             """,
             [now, removed_by, id]
           ),
         {:ok, rule} <- lookup_row(state.conn, id) do
      publish(state.event_bus, %{
        type: :autonomy_scope_mode_changed,
        area: current.scope,
        policy_id: current.policy_id,
        mode: current.mode,
        status: "removed"
      })

      {:reply, {:ok, rule}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:effective, scope, policy_id, fallback_mode, _opts}, _from, state) do
    scope = normalize(scope)
    policy_id = normalize(policy_id)
    fallback_mode = normalize(fallback_mode)
    rules = active_rows(state.conn)
    {:reply, resolve(rules, scope, policy_id, fallback_mode), state}
  end

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.conn)

  def migrate(conn) do
    Sqlite3.execute(conn, """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;

    CREATE TABLE IF NOT EXISTS home_autonomy_scope_modes (
      id TEXT PRIMARY KEY,
      scope TEXT NOT NULL,
      policy_id TEXT,
      mode TEXT NOT NULL,
      changed_by TEXT NOT NULL,
      reason TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      superseded_at TEXT,
      removed_at TEXT,
      removed_by TEXT
    );

    CREATE UNIQUE INDEX IF NOT EXISTS home_autonomy_scope_modes_active_idx
      ON home_autonomy_scope_modes(scope, COALESCE(policy_id, ''))
      WHERE status = 'active';
    CREATE INDEX IF NOT EXISTS home_autonomy_scope_modes_history_idx
      ON home_autonomy_scope_modes(scope, policy_id, created_at DESC);
    """)
  end

  def resolve(rules, scope, policy_id, fallback_mode) when is_list(rules) do
    scope = normalize(scope)
    policy_id = normalize(policy_id)
    fallback_mode = normalize(fallback_mode)

    global = find_rule(rules, "home", nil)

    selected =
      cond do
        global && global.mode == "off" -> {global, "global_off"}
        rule = find_rule(rules, scope, policy_id) -> {rule, "area_policy"}
        rule = find_rule(rules, scope, nil) -> {rule, "area"}
        rule = find_rule(rules, "home", policy_id) -> {rule, "policy"}
        global -> {global, "home"}
        true -> nil
      end

    case selected do
      {rule, precedence} ->
        %{
          mode: String.to_existing_atom(rule.mode),
          source: "configured_rule",
          precedence: precedence,
          rule_id: rule.id,
          scope: rule.scope,
          policy_id: rule.policy_id,
          changed_by: rule.changed_by,
          reason: rule.reason
        }

      nil ->
        %{
          mode: safe_fallback(fallback_mode),
          source: "runtime_default",
          precedence: "runtime_default",
          rule_id: nil,
          scope: "home",
          policy_id: policy_id,
          changed_by: nil,
          reason: nil
        }
    end
  end

  defp active_rows(conn) do
    query(conn, select_sql("WHERE status = 'active' ORDER BY created_at DESC"), [])
    |> Enum.map(&decode/1)
  end

  defp find_rule(rules, scope, policy_id) do
    Enum.find(rules, &(&1.scope == scope and &1.policy_id == policy_id))
  end

  defp persist_rule(conn, id, scope, policy_id, mode, changed_by, reason, now) do
    transaction(conn, fn ->
      with :ok <- supersede(conn, scope, policy_id, now),
           :ok <-
             execute(
               conn,
               """
               INSERT INTO home_autonomy_scope_modes
                 (id, scope, policy_id, mode, changed_by, reason, status, created_at)
               VALUES (?, ?, ?, ?, ?, ?, 'active', ?)
               """,
               [
                 id,
                 scope,
                 policy_id,
                 mode,
                 changed_by,
                 reason,
                 DateTime.to_iso8601(now)
               ]
             ) do
        :ok
      end
    end)
  end

  defp supersede(conn, scope, policy_id, now) do
    execute(
      conn,
      """
      UPDATE home_autonomy_scope_modes
      SET status = 'superseded', superseded_at = ?
      WHERE scope = ? AND COALESCE(policy_id, '') = COALESCE(?, '') AND status = 'active'
      """,
      [DateTime.to_iso8601(now), scope, policy_id]
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
    SELECT id, scope, policy_id, mode, changed_by, reason, status, created_at,
           superseded_at, removed_at, removed_by
    FROM home_autonomy_scope_modes #{suffix}
    """
  end

  defp decode([
         id,
         scope,
         policy_id,
         mode,
         changed_by,
         reason,
         status,
         created_at,
         superseded_at,
         removed_at,
         removed_by
       ]) do
    %{
      id: id,
      scope: scope,
      policy_id: policy_id,
      mode: mode,
      changed_by: changed_by,
      reason: reason,
      status: status,
      created_at: created_at,
      superseded_at: superseded_at,
      removed_at: removed_at,
      removed_by: removed_by
    }
  end

  defp validate_policy(nil, _opts), do: :ok

  defp validate_policy(policy_id, opts) do
    case Zaik.Home.Policies.Registry.fetch(
           policy_id,
           Keyword.get(opts, :policy_registry_opts, [])
         ) do
      {:ok, _policy} -> :ok
      {:error, _reason} -> {:error, {:unknown_autonomy_policy, policy_id}}
    end
  end

  defp validate_mode(mode) when mode in @modes, do: :ok
  defp validate_mode(mode), do: {:error, {:execution_mode_not_enabled, mode}}
  defp validate_scope(""), do: {:error, {:invalid_autonomy_scope_mode, :scope}}
  defp validate_scope(_scope), do: :ok
  defp validate_text(field, ""), do: {:error, {:invalid_autonomy_scope_mode, field}}
  defp validate_text(_field, _value), do: :ok
  defp active_rule(%{status: "active"}), do: :ok
  defp active_rule(rule), do: {:error, {:autonomy_scope_mode_not_active, rule.id}}

  defp safe_fallback(mode) when mode in @modes, do: String.to_existing_atom(mode)
  defp safe_fallback(_mode), do: :off

  defp rule_id(scope, policy_id, mode, changed_by, now) do
    {scope, policy_id, mode, changed_by, DateTime.to_iso8601(now),
     System.unique_integer([:positive])}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("autonomy_mode_" <> String.slice(&1, 0, 24)))
  end

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

  defp transaction(conn, fun) do
    with :ok <- Sqlite3.execute(conn, "BEGIN IMMEDIATE") do
      case fun.() do
        :ok ->
          case Sqlite3.execute(conn, "COMMIT") do
            :ok ->
              :ok

            error ->
              _ = Sqlite3.execute(conn, "ROLLBACK")
              error
          end

        error ->
          _ = Sqlite3.execute(conn, "ROLLBACK")
          error
      end
    end
  rescue
    error ->
      _ = Sqlite3.execute(conn, "ROLLBACK")
      {:error, error}
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
          {:row, _row} -> :ok
          :busy -> {:error, :busy}
          {:error, reason} -> {:error, reason}
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp normalize_optional(nil), do: nil
  defp normalize_optional(""), do: nil
  defp normalize_optional(value), do: normalize(value)
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp expand_path(":memory:"), do: ":memory:"
  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)
end

defmodule Zaik.Home.Autonomy.ActionBudgetStore do
  @moduledoc """
  Durable, sliding-window rate budgets for autonomous physical actions.

  Assessment is read-only and accounts for all actions in a proposed batch.
  Events are recorded only after an execution boundary accepts an autonomous
  action; shadow and advisory decisions never consume budget.
  """

  use GenServer
  alias Exqlite.Sqlite3

  @default_limits %{
    device: %{max_actions: 2, window_seconds: 15 * 60},
    room: %{max_actions: 5, window_seconds: 15 * 60},
    global: %{max_actions: 10, window_seconds: 15 * 60}
  }

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put_new(server_opts, :name, __MODULE__))
  end

  def assess(actions, scope, opts \\ [], server \\ __MODULE__) when is_list(actions),
    do: GenServer.call(server, {:assess, actions, to_string(scope), opts})

  def record(actions, metadata, server \\ __MODULE__)
      when is_list(actions) and is_map(metadata),
      do: GenServer.call(server, {:record, actions, metadata})

  def authorize_and_record(actions, metadata, opts \\ [], server \\ __MODULE__)
      when is_list(actions) and is_map(metadata),
      do: GenServer.call(server, {:authorize_and_record, actions, metadata, opts})

  def usage(scope \\ "home", opts \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:usage, to_string(scope), opts})

  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :db_path, Zaik.Home.HistoryStore.config().db_path) |> expand_path()
    unless path == ":memory:", do: path |> Path.dirname() |> File.mkdir_p!()

    with {:ok, conn} <- Sqlite3.open(path),
         :ok <- migrate(conn),
         {:ok, limits} <- normalize_limits(Keyword.get(opts, :limits, configured_limits())) do
      {:ok, %{conn: conn, clock: Keyword.get(opts, :clock), limits: limits}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:assess, actions, scope, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    limits = Keyword.get(opts, :limits, state.limits)

    reply =
      with {:ok, limits} <- normalize_limits(limits) do
        events = recent_events(state.conn, now, limits)
        {:ok, assess_actions(actions, scope, events, now, limits)}
      end

    {:reply, reply, state}
  end

  def handle_call({:record, actions, metadata}, _from, state) do
    {:reply, record_actions(state, actions, metadata), state}
  end

  def handle_call({:authorize_and_record, actions, metadata, opts}, _from, state) do
    now =
      (value(metadata, :occurred_at) || Zaik.Time.now(Keyword.get(opts, :clock, state.clock)))
      |> parse_time()

    scope = to_string(value(metadata, :scope) || "home")
    limits = Keyword.get(opts, :limits, state.limits)

    reply =
      with {:ok, limits} <- normalize_limits(limits) do
        assessment =
          assess_actions(actions, scope, recent_events(state.conn, now, limits), now, limits)

        if assessment.blocked == [] do
          case record_actions_transaction(state, actions, Map.put(metadata, :occurred_at, now)) do
            {:ok, ids} -> {:ok, %{assessment: assessment, event_ids: ids}}
            error -> error
          end
        else
          {:error, {:action_budget_exceeded, assessment}}
        end
      end

    {:reply, reply, state}
  end

  def handle_call({:usage, scope, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    events = recent_events(state.conn, now, state.limits)
    {:reply, usage_summary(events, scope, now, state.limits), state}
  end

  def handle_call(:reset, _from, state),
    do:
      {:reply, Sqlite3.execute(state.conn, "DELETE FROM home_autonomy_action_budget_events"),
       state}

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.conn)

  def migrate(conn) do
    Sqlite3.execute(conn, """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;

    CREATE TABLE IF NOT EXISTS home_autonomy_action_budget_events (
      id TEXT PRIMARY KEY,
      decision_id TEXT NOT NULL,
      scope TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      capability TEXT NOT NULL,
      occurred_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS home_autonomy_action_budget_events_time_idx
      ON home_autonomy_action_budget_events(occurred_at);

    CREATE INDEX IF NOT EXISTS home_autonomy_action_budget_events_scope_idx
      ON home_autonomy_action_budget_events(scope, entity_id, occurred_at);
    """)
  end

  defp record_actions_transaction(state, actions, metadata) do
    with :ok <- execute(state.conn, "BEGIN IMMEDIATE", []),
         {:ok, ids} <- record_actions(state, actions, metadata),
         :ok <- execute(state.conn, "COMMIT", []) do
      {:ok, ids}
    else
      {:error, reason} ->
        _ = execute(state.conn, "ROLLBACK", [])
        {:error, reason}
    end
  end

  defp record_actions(state, actions, metadata) do
    now = value(metadata, :occurred_at) || Zaik.Time.now(state.clock)
    formatted_now = format_time(now)
    decision_id = to_string(value(metadata, :decision_id) || "unknown")
    scope = to_string(value(metadata, :scope) || "home")

    actions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {action, index}, {:ok, ids} ->
      id = event_id(decision_id, action, index)

      case execute(
             state.conn,
             """
             INSERT OR IGNORE INTO home_autonomy_action_budget_events
               (id, decision_id, scope, entity_id, capability, occurred_at)
             VALUES (?, ?, ?, ?, ?, ?)
             """,
             [
               id,
               decision_id,
               scope,
               to_string(value(action, :entity_id) || "unknown"),
               to_string(value(action, :capability) || "unknown"),
               formatted_now
             ]
           ) do
        :ok -> {:cont, {:ok, [id | ids]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ids} ->
        prune_expired(state.conn, formatted_now, state.limits)
        {:ok, Enum.reverse(ids)}

      error ->
        error
    end
  end

  defp assess_actions(actions, scope, events, now, limits) do
    {allowed, blocked, _planned} =
      Enum.reduce(actions, {[], [], []}, fn action, {allowed, blocked, planned} ->
        exceeded = exceeded_dimensions(action, scope, events ++ planned, now, limits)

        if exceeded == [] do
          virtual = %{
            scope: scope,
            entity_id: to_string(value(action, :entity_id) || "unknown"),
            capability: to_string(value(action, :capability) || "unknown"),
            occurred_at: now
          }

          {[action | allowed], blocked, [virtual | planned]}
        else
          {allowed,
           [%{action: action, reason: "action_budget_exceeded", dimensions: exceeded} | blocked],
           planned}
        end
      end)

    %{
      status: if(blocked == [], do: "allowed", else: "blocked"),
      scope: scope,
      limits: limits,
      usage: usage_summary(events, scope, now, limits),
      allowed: Enum.reverse(allowed),
      blocked: Enum.reverse(blocked),
      assessed_at: DateTime.to_iso8601(now)
    }
  end

  defp exceeded_dimensions(action, scope, events, now, limits) do
    entity_id = to_string(value(action, :entity_id) || "unknown")

    [
      {:device, &(&1.entity_id == entity_id)},
      {:room, &(&1.scope == scope)},
      {:global, fn _event -> true end}
    ]
    |> Enum.flat_map(fn {dimension, predicate} ->
      limit = Map.fetch!(limits, dimension)
      count = count(events, now, limit.window_seconds, predicate)

      if count >= limit.max_actions do
        [
          %{
            dimension: to_string(dimension),
            current: count,
            max_actions: limit.max_actions,
            window_seconds: limit.window_seconds
          }
        ]
      else
        []
      end
    end)
  end

  defp usage_summary(events, scope, now, limits) do
    %{
      room: dimension_usage(events, now, limits.room, &(&1.scope == scope)),
      global: dimension_usage(events, now, limits.global, fn _event -> true end),
      devices:
        events
        |> Enum.filter(&(&1.scope == scope))
        |> Enum.map(& &1.entity_id)
        |> Enum.uniq()
        |> Enum.sort()
        |> Map.new(fn entity_id ->
          {entity_id, dimension_usage(events, now, limits.device, &(&1.entity_id == entity_id))}
        end)
    }
  end

  defp dimension_usage(events, now, limit, predicate) do
    %{
      current: count(events, now, limit.window_seconds, predicate),
      max_actions: limit.max_actions,
      window_seconds: limit.window_seconds
    }
  end

  defp count(events, now, window_seconds, predicate) do
    cutoff = DateTime.add(now, -window_seconds, :second)
    Enum.count(events, &(predicate.(&1) and not DateTime.before?(&1.occurred_at, cutoff)))
  end

  defp recent_events(conn, now, limits) do
    maximum_window = limits |> Map.values() |> Enum.map(& &1.window_seconds) |> Enum.max()
    cutoff = now |> DateTime.add(-maximum_window, :second) |> DateTime.to_iso8601()

    query(
      conn,
      "SELECT scope, entity_id, capability, occurred_at FROM home_autonomy_action_budget_events WHERE julianday(occurred_at) >= julianday(?) ORDER BY occurred_at ASC",
      [cutoff]
    )
    |> Enum.flat_map(fn [scope, entity_id, capability, occurred_at] ->
      case DateTime.from_iso8601(occurred_at) do
        {:ok, datetime, _offset} ->
          [%{scope: scope, entity_id: entity_id, capability: capability, occurred_at: datetime}]

        _ ->
          []
      end
    end)
  end

  defp prune_expired(conn, now, limits) do
    maximum_window = limits |> Map.values() |> Enum.map(& &1.window_seconds) |> Enum.max()

    cutoff =
      now |> parse_time() |> DateTime.add(-maximum_window, :second) |> DateTime.to_iso8601()

    execute(
      conn,
      "DELETE FROM home_autonomy_action_budget_events WHERE julianday(occurred_at) < julianday(?)",
      [cutoff]
    )
  end

  defp parse_time(%DateTime{} = value), do: value

  defp parse_time(value) when is_binary(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  defp configured_limits do
    Application.get_env(:zaik, :home_autonomy, [])
    |> Keyword.get(:action_budgets, @default_limits)
  end

  defp normalize_limits(limits) when is_list(limits), do: normalize_limits(Map.new(limits))

  defp normalize_limits(limits) when is_map(limits) do
    normalized =
      Map.new([:device, :room, :global], fn dimension ->
        raw = Map.get(limits, dimension) || Map.get(limits, to_string(dimension)) || %{}

        {dimension,
         %{
           max_actions: value(raw, :max_actions),
           window_seconds: value(raw, :window_seconds)
         }}
      end)

    if Enum.all?(normalized, fn {_dimension, limit} ->
         is_integer(limit.max_actions) and limit.max_actions > 0 and
           is_integer(limit.window_seconds) and limit.window_seconds > 0
       end) do
      {:ok, normalized}
    else
      {:error, :invalid_action_budget_limits}
    end
  end

  defp normalize_limits(_limits), do: {:error, :invalid_action_budget_limits}

  defp event_id(decision_id, action, index) do
    {decision_id, to_string(value(action, :entity_id)), to_string(value(action, :capability)),
     index}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
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

  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: value
  defp value(nil, _key), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp expand_path(":memory:"), do: ":memory:"
  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)
end

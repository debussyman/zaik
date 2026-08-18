defmodule Zaik.TelemetryStore do
  @moduledoc """
  SQLite-backed operational telemetry projection for Zaik.

  The live OTP stores remain the control-plane source of truth. This store keeps
  queryable operational history for agents, dashboards, and diagnostics.
  """

  use GenServer
  require Logger

  alias Exqlite.Sqlite3

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def config do
    configured = Application.get_env(:zaik, :telemetry_store, [])

    %{
      enabled: env_bool("ZAIK_TELEMETRY_ENABLED", Keyword.get(configured, :enabled, true)),
      db_path:
        System.get_env("ZAIK_TELEMETRY_DB") ||
          Keyword.get(configured, :db_path, "~/.zaik/zaik.db")
    }
  end

  def db_path do
    config().db_path |> expand_path()
  end

  def record_task(%Zaik.Task{} = task, event_type \\ :upsert, metadata \\ %{}),
    do: record_task(__MODULE__, task, event_type, metadata)

  def record_task(server, %Zaik.Task{} = task, event_type, metadata) when is_map(metadata),
    do: GenServer.call(server, {:record_task, task, event_type, metadata})

  def record_session(%Zaik.Session{} = session), do: record_session(__MODULE__, session)

  def record_session(server, %Zaik.Session{} = session),
    do: GenServer.call(server, {:record_session, session})

  def record_session_entry(%Zaik.Session{} = session, entry) when is_map(entry),
    do: record_session_entry(__MODULE__, session, entry)

  def record_session_entry(server, %Zaik.Session{} = session, entry) when is_map(entry),
    do: GenServer.call(server, {:record_session_entry, session, entry})

  def record_llm_call(attrs) when is_map(attrs), do: record_llm_call(__MODULE__, attrs)

  def record_llm_call(server, attrs) when is_map(attrs),
    do: GenServer.call(server, {:record_llm_call, attrs})

  def record_watchdog_scan(summary) when is_map(summary),
    do: record_watchdog_scan(__MODULE__, summary)

  def record_watchdog_scan(server, summary) when is_map(summary),
    do: GenServer.call(server, {:record_watchdog_scan, summary})

  def record_agent_chat_run(attrs) when is_map(attrs),
    do: record_agent_chat_run(__MODULE__, attrs)

  def record_agent_chat_run(server, attrs) when is_map(attrs),
    do: GenServer.call(server, {:record_agent_chat_run, attrs})

  def create_proposal(attrs) when is_map(attrs), do: create_proposal(__MODULE__, attrs)

  def create_proposal(server, attrs) when is_map(attrs),
    do: GenServer.call(server, {:create_proposal, attrs})

  def list_proposals(status \\ nil), do: list_proposals(__MODULE__, status)
  def list_proposals(server, status), do: GenServer.call(server, {:list_proposals, status})

  def get_proposal(id), do: get_proposal(__MODULE__, id)
  def get_proposal(server, id), do: GenServer.call(server, {:get_proposal, id})

  def decide_proposal(id, decision, decided_by \\ nil),
    do: decide_proposal(__MODULE__, id, decision, decided_by)

  def decide_proposal(server, id, decision, decided_by)
      when decision in [:approved, :rejected, "approved", "rejected"],
      do: GenServer.call(server, {:decide_proposal, id, decision, decided_by})

  def query(sql, params \\ [], opts \\ []), do: query(__MODULE__, sql, params, opts)

  def query(server, sql, params, opts) when is_binary(sql) and is_list(params) and is_list(opts),
    do: GenServer.call(server, {:query, sql, params, opts}, Keyword.get(opts, :timeout, 30_000))

  def safe_record_task(%Zaik.Task{} = task, event_type \\ :upsert, metadata \\ %{}),
    do: safe_call(fn -> record_task(task, event_type, metadata) end)

  def safe_record_session(%Zaik.Session{} = session),
    do: safe_call(fn -> record_session(session) end)

  def safe_record_session_entry(%Zaik.Session{} = session, entry) when is_map(entry),
    do: safe_call(fn -> record_session_entry(session, entry) end)

  def safe_record_llm_call(attrs) when is_map(attrs),
    do: safe_call(fn -> record_llm_call(attrs) end)

  def safe_record_watchdog_scan(summary) when is_map(summary),
    do: safe_call(fn -> record_watchdog_scan(summary) end)

  def safe_record_agent_chat_run(attrs) when is_map(attrs),
    do: safe_call(fn -> record_agent_chat_run(attrs) end)

  @impl true
  def init(opts) do
    cfg = Map.merge(config(), Map.new(opts))

    if cfg.enabled do
      db_path = expand_path(cfg.db_path)

      unless db_path == ":memory:" do
        db_path |> Path.dirname() |> File.mkdir_p!()
      end

      with {:ok, conn} <- Sqlite3.open(db_path),
           :ok <- migrate(conn) do
        {:ok, %{conn: conn, config: cfg}}
      else
        {:error, reason} -> {:stop, reason}
      end
    else
      {:ok, %{conn: nil, config: cfg}}
    end
  end

  @impl true
  def handle_call(_message, _from, %{conn: nil} = state), do: {:reply, :ignored, state}

  def handle_call({:record_task, task, event_type, metadata}, _from, state) do
    result =
      with :ok <- upsert_task(state.conn, task),
           :ok <- insert_task_event(state.conn, task, event_type, metadata) do
        :ok
      end

    {:reply, result, state}
  end

  def handle_call({:record_session, session}, _from, state) do
    {:reply, upsert_session(state.conn, session), state}
  end

  def handle_call({:record_session_entry, session, entry}, _from, state) do
    result =
      with :ok <- upsert_session(state.conn, session),
           :ok <- insert_session_entry(state.conn, session, entry) do
        maybe_insert_message(state.conn, session, entry)
      end

    {:reply, result, state}
  end

  def handle_call({:record_llm_call, attrs}, _from, state) do
    {:reply, insert_llm_call(state.conn, attrs), state}
  end

  def handle_call({:record_watchdog_scan, summary}, _from, state) do
    {:reply, insert_watchdog_scan(state.conn, summary), state}
  end

  def handle_call({:record_agent_chat_run, attrs}, _from, state) do
    {:reply, insert_agent_chat_run(state.conn, attrs), state}
  end

  def handle_call({:create_proposal, attrs}, _from, state) do
    {:reply, insert_proposal(state.conn, attrs), state}
  end

  def handle_call({:list_proposals, status}, _from, state) do
    {:reply, select_proposals(state.conn, status), state}
  end

  def handle_call({:get_proposal, id}, _from, state) do
    {:reply, select_proposal(state.conn, id), state}
  end

  def handle_call({:decide_proposal, id, decision, decided_by}, _from, state) do
    {:reply, update_proposal_decision(state.conn, id, decision, decided_by), state}
  end

  def handle_call({:query, sql, params, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 500)
    {:reply, select(state.conn, sql, params, limit), state}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn) do
    Sqlite3.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp migrate(conn) do
    with :ok <-
           Sqlite3.execute(conn, """
           PRAGMA journal_mode = WAL;
           PRAGMA synchronous = NORMAL;
           PRAGMA foreign_keys = ON;

           CREATE TABLE IF NOT EXISTS ops_tasks (
             id TEXT PRIMARY KEY,
             type TEXT NOT NULL,
             status TEXT NOT NULL,
             session_id TEXT,
             priority INTEGER,
             submitted_at TEXT,
             started_at TEXT,
             completed_at TEXT,
             attempts INTEGER,
             max_retries INTEGER,
             timeout_ms INTEGER,
             duration_ms INTEGER,
             result_json TEXT,
             error_json TEXT,
             metadata_json TEXT NOT NULL DEFAULT '{}',
             updated_at TEXT NOT NULL
           );

           CREATE TABLE IF NOT EXISTS ops_task_events (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             task_id TEXT NOT NULL,
             event_type TEXT NOT NULL,
             occurred_at TEXT NOT NULL,
             status TEXT,
             metadata_json TEXT NOT NULL DEFAULT '{}'
           );

           CREATE INDEX IF NOT EXISTS ops_task_events_task_time_idx
             ON ops_task_events(task_id, occurred_at);

           CREATE INDEX IF NOT EXISTS ops_tasks_status_time_idx
             ON ops_tasks(status, submitted_at);

           CREATE TABLE IF NOT EXISTS ops_sessions (
             id TEXT PRIMARY KEY,
             scope TEXT,
             cwd TEXT,
             path TEXT,
             created_at TEXT,
             updated_at TEXT,
             metadata_json TEXT NOT NULL DEFAULT '{}'
           );

           CREATE INDEX IF NOT EXISTS ops_sessions_scope_updated_idx
             ON ops_sessions(scope, updated_at);

           CREATE TABLE IF NOT EXISTS ops_session_entries (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             session_id TEXT NOT NULL,
             entry_id TEXT NOT NULL,
             parent_entry_id TEXT,
             entry_type TEXT,
             created_at TEXT,
             entry_json TEXT NOT NULL,
             UNIQUE(session_id, entry_id)
           );

           CREATE INDEX IF NOT EXISTS ops_session_entries_session_time_idx
             ON ops_session_entries(session_id, created_at);

           CREATE TABLE IF NOT EXISTS ops_messages (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             session_id TEXT NOT NULL,
             entry_id TEXT NOT NULL,
             role TEXT,
             content TEXT,
             channel TEXT,
             sender_id TEXT,
             chat_id TEXT,
             created_at TEXT,
             metadata_json TEXT NOT NULL DEFAULT '{}',
             UNIQUE(session_id, entry_id)
           );

           CREATE INDEX IF NOT EXISTS ops_messages_session_time_idx
             ON ops_messages(session_id, created_at);

           CREATE INDEX IF NOT EXISTS ops_messages_channel_time_idx
             ON ops_messages(channel, created_at);

           CREATE TABLE IF NOT EXISTS ops_llm_calls (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             purpose TEXT,
             model TEXT,
             success INTEGER NOT NULL,
             duration_ms INTEGER,
             total_duration_ms INTEGER,
             load_duration_ms INTEGER,
             prompt_eval_count INTEGER,
             eval_count INTEGER,
             response_length INTEGER,
             error_json TEXT,
             metadata_json TEXT NOT NULL DEFAULT '{}',
             created_at TEXT NOT NULL
           );

           CREATE INDEX IF NOT EXISTS ops_llm_calls_created_idx
             ON ops_llm_calls(created_at);

           CREATE TABLE IF NOT EXISTS ops_watchdog_scans (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             scanned_at TEXT NOT NULL,
             summary_json TEXT NOT NULL
           );

           CREATE INDEX IF NOT EXISTS ops_watchdog_scans_time_idx
             ON ops_watchdog_scans(scanned_at);

           CREATE TABLE IF NOT EXISTS ops_agent_chat_runs (
             id TEXT PRIMARY KEY,
             prompt TEXT NOT NULL,
             context_json TEXT NOT NULL DEFAULT '{}',
             channel TEXT,
             sender_id TEXT,
             chat_id TEXT,
             chat_type TEXT,
             session_id TEXT,
             primary_model TEXT,
             fallback_model TEXT,
             fallback_used INTEGER NOT NULL DEFAULT 0,
             final_model TEXT,
             status TEXT NOT NULL,
             answer TEXT,
             error_json TEXT,
             tool_calls_json TEXT NOT NULL DEFAULT '[]',
             duration_ms INTEGER,
             metadata_json TEXT NOT NULL DEFAULT '{}',
             created_at TEXT NOT NULL
           );

           CREATE INDEX IF NOT EXISTS ops_agent_chat_runs_created_idx
             ON ops_agent_chat_runs(created_at);

           CREATE INDEX IF NOT EXISTS ops_agent_chat_runs_model_status_idx
             ON ops_agent_chat_runs(primary_model, status, created_at);

           CREATE TABLE IF NOT EXISTS ops_proposals (
             id TEXT PRIMARY KEY,
             status TEXT NOT NULL,
             type TEXT NOT NULL,
             title TEXT NOT NULL,
             body TEXT NOT NULL,
             action_json TEXT NOT NULL DEFAULT '{}',
             metadata_json TEXT NOT NULL DEFAULT '{}',
             created_by TEXT,
             decided_by TEXT,
             created_at TEXT NOT NULL,
             decided_at TEXT
           );

           CREATE INDEX IF NOT EXISTS ops_proposals_status_created_idx
             ON ops_proposals(status, created_at);

           CREATE VIEW IF NOT EXISTS zaik_tasks AS
             SELECT id, type, status, session_id, priority, submitted_at, started_at, completed_at,
                    attempts, max_retries, timeout_ms, duration_ms, result_json, error_json,
                    metadata_json, updated_at
             FROM ops_tasks;

           CREATE VIEW IF NOT EXISTS zaik_task_events AS
             SELECT id, task_id, event_type, occurred_at, status, metadata_json
             FROM ops_task_events;

           CREATE VIEW IF NOT EXISTS zaik_sessions AS
             SELECT id, scope, cwd, path, created_at, updated_at, metadata_json
             FROM ops_sessions;

           CREATE VIEW IF NOT EXISTS zaik_messages AS
             SELECT id, session_id, entry_id, role, content, channel, sender_id, chat_id,
                    created_at, metadata_json
             FROM ops_messages;

           CREATE VIEW IF NOT EXISTS zaik_llm_calls AS
             SELECT id, purpose, model, success, duration_ms, total_duration_ms,
                    load_duration_ms, prompt_eval_count, eval_count, response_length,
                    error_json, metadata_json, created_at
             FROM ops_llm_calls;

           CREATE VIEW IF NOT EXISTS zaik_watchdog_scans AS
             SELECT id, scanned_at, summary_json
             FROM ops_watchdog_scans;

           CREATE VIEW IF NOT EXISTS zaik_agent_chat_runs AS
             SELECT id, prompt, context_json, channel, sender_id, chat_id, chat_type,
                    session_id, primary_model, fallback_model, fallback_used, final_model,
                    status, answer, error_json, tool_calls_json, duration_ms,
                    metadata_json, created_at
             FROM ops_agent_chat_runs;

           CREATE VIEW IF NOT EXISTS zaik_proposals AS
             SELECT id, status, type, title, body, action_json, metadata_json,
                    created_by, decided_by, created_at, decided_at
             FROM ops_proposals;
           """),
         :ok <- ensure_agent_chat_run_columns(conn),
         :ok <- recreate_agent_chat_run_view(conn) do
      :ok
    end
  end

  defp ensure_agent_chat_run_columns(conn) do
    columns = existing_columns(conn, "ops_agent_chat_runs")

    [
      {"channel", "TEXT"},
      {"sender_id", "TEXT"},
      {"chat_id", "TEXT"},
      {"chat_type", "TEXT"},
      {"session_id", "TEXT"}
    ]
    |> Enum.reduce_while(:ok, fn {column, type}, :ok ->
      if column in columns do
        {:cont, :ok}
      else
        case Sqlite3.execute(conn, "ALTER TABLE ops_agent_chat_runs ADD COLUMN #{column} #{type}") do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp existing_columns(conn, table) do
    conn
    |> query_rows("PRAGMA table_info(#{table})", [])
    |> Enum.map(fn row -> Enum.at(row, 1) end)
  end

  defp recreate_agent_chat_run_view(conn) do
    with :ok <- Sqlite3.execute(conn, "DROP VIEW IF EXISTS zaik_agent_chat_runs") do
      Sqlite3.execute(conn, """
      CREATE VIEW zaik_agent_chat_runs AS
        SELECT id, prompt, context_json, channel, sender_id, chat_id, chat_type,
               session_id, primary_model, fallback_model, fallback_used, final_model,
               status, answer, error_json, tool_calls_json, duration_ms,
               metadata_json, created_at
        FROM ops_agent_chat_runs;
      """)
    end
  end

  defp upsert_task(conn, task) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    exec(
      conn,
      """
      INSERT INTO ops_tasks (
        id, type, status, session_id, priority, submitted_at, started_at, completed_at,
        attempts, max_retries, timeout_ms, duration_ms, result_json, error_json,
        metadata_json, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        type = excluded.type,
        status = excluded.status,
        session_id = excluded.session_id,
        priority = excluded.priority,
        submitted_at = excluded.submitted_at,
        started_at = excluded.started_at,
        completed_at = excluded.completed_at,
        attempts = excluded.attempts,
        max_retries = excluded.max_retries,
        timeout_ms = excluded.timeout_ms,
        duration_ms = excluded.duration_ms,
        result_json = excluded.result_json,
        error_json = excluded.error_json,
        metadata_json = excluded.metadata_json,
        updated_at = excluded.updated_at
      """,
      [
        task.id,
        to_string(task.type),
        to_string(task.status),
        task.session_id,
        task.priority,
        iso(task.submitted_at),
        iso(task.started_at),
        iso(task.completed_at),
        task.attempts,
        task.max_retries,
        task.timeout_ms,
        duration_ms(task),
        encode_value(task.result),
        encode_value(task.error),
        Jason.encode!(task.metadata || %{}),
        now
      ]
    )
  end

  defp insert_task_event(conn, task, event_type, metadata) do
    exec(
      conn,
      """
      INSERT INTO ops_task_events (task_id, event_type, occurred_at, status, metadata_json)
      VALUES (?, ?, ?, ?, ?)
      """,
      [
        task.id,
        inspect(event_type),
        DateTime.utc_now() |> DateTime.to_iso8601(),
        to_string(task.status),
        Jason.encode!(metadata || %{})
      ]
    )
  end

  defp upsert_session(conn, session) do
    exec(
      conn,
      """
      INSERT INTO ops_sessions (id, scope, cwd, path, created_at, updated_at, metadata_json)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        scope = excluded.scope,
        cwd = excluded.cwd,
        path = excluded.path,
        updated_at = excluded.updated_at,
        metadata_json = excluded.metadata_json
      """,
      [
        session.id,
        to_string(session.scope),
        session.cwd,
        session.path,
        iso(session.created_at),
        iso(session.updated_at),
        Jason.encode!(session.metadata || %{})
      ]
    )
  end

  defp insert_session_entry(conn, session, entry) do
    exec(
      conn,
      """
      INSERT INTO ops_session_entries (
        session_id, entry_id, parent_entry_id, entry_type, created_at, entry_json
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(session_id, entry_id) DO UPDATE SET
        parent_entry_id = excluded.parent_entry_id,
        entry_type = excluded.entry_type,
        created_at = excluded.created_at,
        entry_json = excluded.entry_json
      """,
      [
        session.id,
        entry["id"],
        entry["parentId"],
        entry["type"],
        entry["timestamp"],
        Jason.encode!(entry)
      ]
    )
  end

  defp maybe_insert_message(conn, session, %{"type" => "message"} = entry) do
    metadata = entry["metadata"] || %{}

    exec(
      conn,
      """
      INSERT INTO ops_messages (
        session_id, entry_id, role, content, channel, sender_id, chat_id, created_at, metadata_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(session_id, entry_id) DO UPDATE SET
        role = excluded.role,
        content = excluded.content,
        channel = excluded.channel,
        sender_id = excluded.sender_id,
        chat_id = excluded.chat_id,
        created_at = excluded.created_at,
        metadata_json = excluded.metadata_json
      """,
      [
        session.id,
        entry["id"],
        entry["role"],
        entry["content"],
        metadata_value(metadata, "channel"),
        metadata_value(metadata, "sender_id") || metadata_value(metadata, "sender"),
        metadata_value(metadata, "chat_id"),
        entry["timestamp"],
        Jason.encode!(metadata)
      ]
    )
  end

  defp maybe_insert_message(_conn, _session, _entry), do: :ok

  defp insert_llm_call(conn, attrs) do
    raw = Map.get(attrs, :raw) || Map.get(attrs, "raw") || %{}
    success = Map.get(attrs, :success) || Map.get(attrs, "success") || false

    exec(
      conn,
      """
      INSERT INTO ops_llm_calls (
        purpose, model, success, duration_ms, total_duration_ms, load_duration_ms,
        prompt_eval_count, eval_count, response_length, error_json, metadata_json, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        map_value(attrs, :purpose),
        map_value(attrs, :model) || Map.get(raw, "model"),
        boolean_integer(success),
        map_value(attrs, :duration_ms),
        Map.get(raw, "total_duration") |> nanos_to_ms(),
        Map.get(raw, "load_duration") |> nanos_to_ms(),
        Map.get(raw, "prompt_eval_count"),
        Map.get(raw, "eval_count"),
        map_value(attrs, :response_length),
        encode_value(map_value(attrs, :error)),
        Jason.encode!(map_value(attrs, :metadata) || %{}),
        DateTime.utc_now() |> DateTime.to_iso8601()
      ]
    )
  end

  defp insert_watchdog_scan(conn, summary) do
    exec(
      conn,
      """
      INSERT INTO ops_watchdog_scans (scanned_at, summary_json)
      VALUES (?, ?)
      """,
      [DateTime.utc_now() |> DateTime.to_iso8601(), Jason.encode!(summary)]
    )
  end

  defp insert_agent_chat_run(conn, attrs) do
    id = map_value(attrs, :id) || run_id("agent_chat")

    exec(
      conn,
      """
      INSERT INTO ops_agent_chat_runs (
        id, prompt, context_json, channel, sender_id, chat_id, chat_type,
        session_id, primary_model, fallback_model, fallback_used, final_model,
        status, answer, error_json, tool_calls_json, duration_ms, metadata_json,
        created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        id,
        to_string(map_value(attrs, :prompt) || ""),
        Jason.encode!(sanitize(map_value(attrs, :context) || %{})),
        map_value(attrs, :channel),
        map_value(attrs, :sender_id),
        map_value(attrs, :chat_id),
        map_value(attrs, :chat_type),
        map_value(attrs, :session_id),
        map_value(attrs, :primary_model),
        map_value(attrs, :fallback_model),
        boolean_integer(map_value(attrs, :fallback_used) || false),
        map_value(attrs, :final_model),
        to_string(map_value(attrs, :status) || :unknown),
        map_value(attrs, :answer),
        encode_value(map_value(attrs, :error)),
        Jason.encode!(sanitize(map_value(attrs, :tool_calls) || [])),
        map_value(attrs, :duration_ms),
        Jason.encode!(sanitize(map_value(attrs, :metadata) || %{})),
        iso(map_value(attrs, :created_at) || DateTime.utc_now())
      ]
    )
  end

  defp insert_proposal(conn, attrs) do
    id = map_value(attrs, :id) || proposal_id()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    result =
      exec(
        conn,
        """
        INSERT INTO ops_proposals (
          id, status, type, title, body, action_json, metadata_json, created_by, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          id,
          to_string(map_value(attrs, :status) || :pending),
          to_string(map_value(attrs, :type) || :general),
          to_string(map_value(attrs, :title) || "Untitled proposal"),
          to_string(map_value(attrs, :body) || ""),
          Jason.encode!(map_value(attrs, :action) || %{}),
          Jason.encode!(map_value(attrs, :metadata) || %{}),
          map_value(attrs, :created_by),
          now
        ]
      )

    case result do
      :ok -> {:ok, select_proposal!(conn, id)}
      error -> error
    end
  end

  defp select_proposals(conn, status) do
    {where, params} =
      case status do
        nil -> {"", []}
        :all -> {"", []}
        "all" -> {"", []}
        value -> {"WHERE status = ?", [to_string(value)]}
      end

    rows =
      query_rows(
        conn,
        """
        SELECT id, status, type, title, body, action_json, metadata_json,
               created_by, decided_by, created_at, decided_at
        FROM ops_proposals
        #{where}
        ORDER BY created_at DESC
        LIMIT 50
        """,
        params
      )

    {:ok, Enum.map(rows, &proposal_from_row/1)}
  end

  defp select_proposal(conn, id) do
    case select_proposal!(conn, id) do
      nil -> {:error, :not_found}
      proposal -> {:ok, proposal}
    end
  end

  defp select_proposal!(conn, id) do
    conn
    |> query_rows(
      """
      SELECT id, status, type, title, body, action_json, metadata_json,
             created_by, decided_by, created_at, decided_at
      FROM ops_proposals
      WHERE id = ?
      LIMIT 1
      """,
      [id]
    )
    |> case do
      [] -> nil
      [row | _] -> proposal_from_row(row)
    end
  end

  defp update_proposal_decision(conn, id, decision, decided_by) do
    decision = to_string(decision)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    with {:ok, proposal} <- select_proposal(conn, id),
         true <- proposal.status == "pending" do
      result =
        exec(
          conn,
          """
          UPDATE ops_proposals
          SET status = ?, decided_by = ?, decided_at = ?
          WHERE id = ?
          """,
          [decision, decided_by, now, id]
        )

      case result do
        :ok -> select_proposal(conn, id)
        error -> error
      end
    else
      false -> {:error, :already_decided}
      error -> error
    end
  end

  defp proposal_from_row([
         id,
         status,
         type,
         title,
         body,
         action_json,
         metadata_json,
         created_by,
         decided_by,
         created_at,
         decided_at
       ]) do
    %{
      id: id,
      status: status,
      type: type,
      title: title,
      body: body,
      action: decode_json(action_json, %{}),
      metadata: decode_json(metadata_json, %{}),
      created_by: created_by,
      decided_by: decided_by,
      created_at: parse_datetime(created_at),
      decided_at: parse_datetime(decided_at)
    }
  end

  defp select(conn, sql, params, limit) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(stmt, params),
             {:ok, columns} <- Sqlite3.columns(conn, stmt),
             {:ok, rows} <- Sqlite3.fetch_all(conn, stmt) do
          rows = Enum.take(rows, limit)

          {:ok,
           %{
             columns: columns,
             rows: Enum.map(rows, &row_map(columns, &1)),
             row_count: length(rows)
           }}
        else
          {:error, reason} -> {:error, reason}
        end
      after
        Sqlite3.release(conn, stmt)
      end
    end
  end

  defp exec(conn, sql, params) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql) do
      try do
        :ok = Sqlite3.bind(stmt, params)

        case Sqlite3.step(conn, stmt) do
          :done -> :ok
          {:row, _row} -> :ok
          {:error, reason} -> {:error, reason}
          :busy -> {:error, :busy}
        end
      after
        Sqlite3.release(conn, stmt)
      end
    end
  end

  defp query_rows(conn, sql, params) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(stmt, params),
             {:ok, rows} <- Sqlite3.fetch_all(conn, stmt) do
          rows
        else
          _error -> []
        end
      after
        Sqlite3.release(conn, stmt)
      end
    else
      _error -> []
    end
  end

  defp row_map(columns, row), do: columns |> Enum.zip(row) |> Map.new()

  defp safe_call(fun) do
    if Process.whereis(__MODULE__) do
      fun.()
    else
      :ignored
    end
  rescue
    error ->
      Logger.debug("Telemetry write ignored after error: #{Exception.message(error)}")
      :ignored
  catch
    :exit, _reason -> :ignored
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, String.to_atom(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp map_value(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp decode_json(nil, default), do: default
  defp decode_json("", default), do: default

  defp decode_json(json, default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  end

  defp decode_json(_json, default), do: default

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> value
    end
  end

  defp parse_datetime(value), do: value

  defp proposal_id, do: run_id("prop")

  defp run_id(prefix) do
    prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  end

  defp duration_ms(%Zaik.Task{
         submitted_at: %DateTime{} = started,
         completed_at: %DateTime{} = completed
       }),
       do: DateTime.diff(completed, started, :millisecond)

  defp duration_ms(_task), do: nil

  defp iso(nil), do: nil
  defp iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso(value), do: to_string(value)

  defp encode_value(nil), do: nil
  defp encode_value(value), do: Jason.encode!(sanitize(value))

  defp sanitize(nil), do: nil
  defp sanitize(value) when is_boolean(value), do: value
  defp sanitize(atom) when is_atom(atom), do: to_string(atom)
  defp sanitize(pid) when is_pid(pid), do: inspect(pid)
  defp sanitize(ref) when is_reference(ref), do: inspect(ref)
  defp sanitize(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&sanitize/1)
  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  defp sanitize(%_{} = struct), do: struct |> Map.from_struct() |> sanitize()

  defp sanitize(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), sanitize(value)} end)

  defp sanitize(value), do: value

  defp boolean_integer(true), do: 1
  defp boolean_integer(false), do: 0
  defp boolean_integer(1), do: 1
  defp boolean_integer(0), do: 0
  defp boolean_integer(_), do: 0

  defp nanos_to_ms(nil), do: nil
  defp nanos_to_ms(nanos) when is_integer(nanos), do: div(nanos, 1_000_000)
  defp nanos_to_ms(_), do: nil

  defp expand_path(":memory:"), do: ":memory:"
  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)

  defp env_bool(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> value |> String.downcase() |> then(&(&1 in ["1", "true", "yes", "on"]))
    end
  end
end

defmodule Zaik.Analytics.SQLTool do
  @moduledoc """
  Safe read-only SQL tool for agent analytics.

  This accepts model-written SQL only after validation, restricts queries to
  documented read-only views, enforces a row cap, and opens SQLite read-only
  when querying standalone databases.
  """

  alias Exqlite.Sqlite3

  @ops_views MapSet.new([
               "zaik_tasks",
               "zaik_task_events",
               "zaik_sessions",
               "zaik_messages",
               "zaik_llm_calls",
               "zaik_watchdog_scans",
               "zaik_proposals"
             ])

  @home_views MapSet.new(["home_devices", "home_readings"])

  @denied ~r/\b(insert|update|delete|drop|alter|pragma|attach|detach|vacuum|replace|create|reindex|truncate)\b/i

  def schema(:ops) do
    """
    Allowed ops views:

    zaik_tasks(id, type, status, session_id, priority, submitted_at, started_at,
      completed_at, attempts, max_retries, timeout_ms, duration_ms, result_json,
      error_json, metadata_json, updated_at)

    zaik_task_events(id, task_id, event_type, occurred_at, status, metadata_json)

    zaik_sessions(id, scope, cwd, path, created_at, updated_at, metadata_json)

    zaik_messages(id, session_id, entry_id, role, content, channel, sender_id,
      chat_id, created_at, metadata_json)

    zaik_llm_calls(id, purpose, model, success, duration_ms, total_duration_ms,
      load_duration_ms, prompt_eval_count, eval_count, response_length,
      error_json, metadata_json, created_at)

    zaik_watchdog_scans(id, scanned_at, summary_json)

    zaik_proposals(id, status, type, title, body, action_json, metadata_json,
      created_by, decided_by, created_at, decided_at)
    """
    |> String.trim()
  end

  def schema(:home) do
    """
    Allowed home views:

    home_devices(id, friendly_name, source, topic, metadata_json, inserted_at, updated_at)

    home_readings(id, device_id, device_name, room, recorded_at, temperature_c,
      temperature_f, humidity, illuminance, presence, pir_detection, battery,
      voltage, linkquality, target_distance, payload_json)
    """
    |> String.trim()
  end

  def allowed_views(:ops), do: MapSet.to_list(@ops_views)
  def allowed_views(:home), do: MapSet.to_list(@home_views)

  def run(sql, opts \\ []) when is_binary(sql) and is_list(opts) do
    db = Keyword.get(opts, :db, :ops)
    limit = Keyword.get(opts, :limit, 200)

    with {:ok, normalized_sql} <- validate(sql, db) do
      case db do
        :ops -> Zaik.TelemetryStore.query(normalized_sql, [], limit: limit)
        :home -> query_file(home_db_path(), normalized_sql, limit)
        other -> {:error, {:unsupported_database, other}}
      end
    end
  end

  def validate(sql, db \\ :ops) when is_binary(sql) do
    normalized = normalize_sql(sql)

    cond do
      normalized == "" ->
        {:error, :empty_query}

      not read_only_start?(normalized) ->
        {:error, :only_select_queries_allowed}

      multiple_statements?(normalized) ->
        {:error, :multiple_statements_not_allowed}

      Regex.match?(@denied, normalized) ->
        {:error, :disallowed_sql_keyword}

      not allowed_relations?(normalized, db) ->
        {:error, {:disallowed_relation, referenced_relations(normalized, db)}}

      true ->
        {:ok, normalized}
    end
  end

  defp query_file(":memory:", _sql, _limit),
    do: {:error, :memory_database_not_queryable_from_sql_tool}

  defp query_file(path, sql, limit) do
    with {:ok, conn} <- Sqlite3.open(path, mode: :readonly) do
      try do
        select(conn, sql, [], limit)
      after
        Sqlite3.close(conn)
      end
    end
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

  defp row_map(columns, row), do: columns |> Enum.zip(row) |> Map.new()

  defp normalize_sql(sql) do
    sql
    |> String.trim()
    |> String.trim_trailing(";")
    |> String.trim()
  end

  defp read_only_start?(sql) do
    downcased = String.downcase(sql)
    String.starts_with?(downcased, "select ") or String.starts_with?(downcased, "with ")
  end

  defp multiple_statements?(sql), do: String.contains?(sql, ";")

  defp allowed_relations?(sql, db) do
    allowed = allowed_set(db)
    referenced = referenced_relations(sql, db)
    Enum.all?(referenced, &MapSet.member?(allowed, &1))
  end

  defp referenced_relations(sql, db) do
    ctes = cte_names(sql)
    allowed = MapSet.union(allowed_set(db), MapSet.new(ctes))

    Regex.scan(~r/\b(?:from|join)\s+([`"\[]?[A-Za-z_][\w.]*[`"\]]?)/i, sql)
    |> Enum.map(fn [_match, relation] -> clean_identifier(relation) end)
    |> Enum.reject(&String.starts_with?(&1, "select"))
    |> Enum.reject(&MapSet.member?(allowed, &1))
    |> Enum.uniq()
  end

  defp allowed_set(:ops), do: @ops_views
  defp allowed_set(:home), do: @home_views
  defp allowed_set(_), do: MapSet.new()

  defp cte_names(sql) do
    case Regex.run(~r/^\s*with\s+(.+?)\s+select\b/is, sql, capture: :all_but_first) do
      [cte_part] ->
        Regex.scan(~r/(?:^|,)\s*([A-Za-z_][\w]*)\s+as\s*\(/i, cte_part)
        |> Enum.map(fn [_match, name] -> String.downcase(name) end)

      _ ->
        []
    end
  end

  defp clean_identifier(identifier) do
    identifier
    |> String.trim()
    |> String.trim_leading("`")
    |> String.trim_trailing("`")
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(".")
    |> List.last()
    |> String.downcase()
  end

  defp home_db_path do
    Zaik.Home.HistoryStore.config().db_path
    |> expand_path()
  end

  defp expand_path(":memory:"), do: ":memory:"
  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)
end

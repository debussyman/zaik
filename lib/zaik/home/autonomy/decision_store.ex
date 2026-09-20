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

  def shadow_evidence(policy_id, scope, server \\ __MODULE__)
      when is_binary(policy_id) and is_binary(scope),
      do: GenServer.call(server, {:shadow_evidence, policy_id, scope})

  def record_outcome(id, outcome, server \\ __MODULE__)
      when is_binary(id) and is_map(outcome),
      do: GenServer.call(server, {:record_outcome, id, outcome})

  def record_feedback(id, feedback, server \\ __MODULE__)
      when is_binary(id) and is_map(feedback),
      do: GenServer.call(server, {:record_feedback, id, feedback})

  def claim_alert_delivery(fingerprint, attrs, opts \\ [], server \\ __MODULE__)
      when is_binary(fingerprint) and is_map(attrs) and is_list(opts),
      do: GenServer.call(server, {:claim_alert_delivery, fingerprint, attrs, opts})

  def complete_alert_delivery(fingerprint, token, server \\ __MODULE__)
      when is_binary(fingerprint) and is_binary(token),
      do: GenServer.call(server, {:complete_alert_delivery, fingerprint, token})

  def release_alert_delivery(fingerprint, token, server \\ __MODULE__)
      when is_binary(fingerprint) and is_binary(token),
      do: GenServer.call(server, {:release_alert_delivery, fingerprint, token})

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

  def handle_call({:shadow_evidence, policy_id, scope}, _from, state) do
    decisions =
      state.conn
      |> query(
        select_sql("WHERE query = ? AND mode IN ('shadow', 'advisory') ORDER BY created_at ASC"),
        [scope]
      )
      |> Enum.map(&decode/1)
      |> Enum.filter(&decision_contains_policy?(&1, policy_id))

    {:reply, summarize_shadow_evidence(decisions, policy_id, scope), state}
  end

  def handle_call({:record_outcome, id, outcome}, _from, state) do
    reply = append_entry(state, id, :outcomes, validate_outcome(outcome))
    {:reply, reply, state}
  end

  def handle_call({:record_feedback, id, feedback}, _from, state) do
    reply = append_entry(state, id, :feedback, validate_feedback(feedback))
    {:reply, reply, state}
  end

  def handle_call({:claim_alert_delivery, fingerprint, attrs, opts}, _from, state) do
    now = Zaik.Time.now(Keyword.get(opts, :clock, state.clock))
    cooldown_seconds = Keyword.get(opts, :cooldown_seconds, 900)
    claim_timeout_seconds = Keyword.get(opts, :claim_timeout_seconds, 60)

    reply =
      with :ok <-
             validate_alert_claim(fingerprint, attrs, cooldown_seconds, claim_timeout_seconds) do
        claim_alert(
          state.conn,
          fingerprint,
          attrs,
          now,
          cooldown_seconds,
          claim_timeout_seconds
        )
      end

    {:reply, reply, state}
  end

  def handle_call({:complete_alert_delivery, fingerprint, token}, _from, state) do
    reply = update_alert_claim(state.conn, fingerprint, token, "completed")
    {:reply, reply, state}
  end

  def handle_call({:release_alert_delivery, fingerprint, token}, _from, state) do
    reply =
      execute(
        state.conn,
        "DELETE FROM home_autonomy_alert_deliveries WHERE fingerprint = ? AND claim_token = ? AND status = 'claimed'",
        [fingerprint, token]
      )

    {:reply, reply, state}
  end

  def handle_call(:reset, _from, state) do
    reply =
      with :ok <- Sqlite3.execute(state.conn, "DELETE FROM home_autonomy_decisions") do
        Sqlite3.execute(state.conn, "DELETE FROM home_autonomy_alert_deliveries")
      end

    {:reply, reply, state}
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

           CREATE TABLE IF NOT EXISTS home_autonomy_alert_deliveries (
             fingerprint TEXT PRIMARY KEY,
             issue_type TEXT NOT NULL,
             details_json TEXT NOT NULL,
             destination_fingerprint TEXT NOT NULL,
             status TEXT NOT NULL,
             claim_token TEXT NOT NULL,
             delivered_at TEXT NOT NULL
           );

           CREATE INDEX IF NOT EXISTS home_autonomy_alert_deliveries_time_idx
             ON home_autonomy_alert_deliveries(delivered_at DESC);
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
        current_entries = Map.fetch!(decision, field)
        entries = append_unique(current_entries, entry) |> Enum.take(-100)
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

  defp decision_contains_policy?(decision, policy_id) do
    decision
    |> Map.get(:candidates, [])
    |> Enum.any?(&(to_string(value(&1, :policy_id)) == policy_id))
  end

  defp summarize_shadow_evidence(decisions, policy_id, scope) do
    capabilities =
      decisions
      |> Enum.flat_map(&Map.get(&1, :candidates, []))
      |> Enum.flat_map(&List.wrap(value(&1, :desired_state)))
      |> Enum.map(&(value(&1, :capability) |> to_string()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    safety_statuses = ~w(failed timed_out non_converged)

    safety_failures =
      decisions
      |> Enum.flat_map(&Map.get(&1, :outcomes, []))
      |> Enum.count(&(to_string(value(&1, :status)) in safety_statuses))

    first_at = decisions |> List.first() |> decision_time()
    last_at = decisions |> List.last() |> decision_time()

    %{
      policy_id: policy_id,
      scope: scope,
      decision_count: length(decisions),
      proposed_count: Enum.count(decisions, &(&1.status == "proposed")),
      blocked_count: Enum.count(decisions, &(&1.status == "blocked")),
      satisfied_count: Enum.count(decisions, &(&1.status == "satisfied")),
      safety_failures: safety_failures,
      capabilities: capabilities,
      first_decision_at: format_optional_time(first_at),
      last_decision_at: format_optional_time(last_at),
      duration_seconds: shadow_duration(first_at, last_at),
      decision_ids: decisions |> Enum.map(& &1.id) |> Enum.take(-100)
    }
  end

  defp decision_time(nil), do: nil

  defp decision_time(decision) do
    case DateTime.from_iso8601(to_string(Map.get(decision, :created_at))) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp shadow_duration(%DateTime{} = first, %DateTime{} = last),
    do: max(0, DateTime.diff(last, first, :second))

  defp shadow_duration(_first, _last), do: 0
  defp format_optional_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_optional_time(_value), do: nil

  defp append_unique(entries, %{"event_id" => event_id} = entry)
       when is_binary(event_id) and event_id != "" do
    if Enum.any?(entries, &(Map.get(&1, "event_id") == event_id)),
      do: entries,
      else: entries ++ [entry]
  end

  defp append_unique(entries, entry), do: entries ++ [entry]

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

  defp validate_alert_claim(fingerprint, attrs, cooldown_seconds, claim_timeout_seconds) do
    issue_type = value(attrs, :issue_type)
    destination = value(attrs, :destination_fingerprint)
    details = Jason.encode!(json_safe(value(attrs, :details) || %{}))

    cond do
      String.trim(fingerprint) == "" or byte_size(fingerprint) > 128 ->
        {:error, :invalid_alert_fingerprint}

      not is_binary(issue_type) or String.trim(issue_type) == "" or byte_size(issue_type) > 100 ->
        {:error, :invalid_alert_type}

      not is_binary(destination) or String.trim(destination) == "" or
          byte_size(destination) > 128 ->
        {:error, :invalid_alert_destination}

      byte_size(details) > 4_096 ->
        {:error, :alert_details_too_large}

      not is_integer(cooldown_seconds) or cooldown_seconds < 1 ->
        {:error, :invalid_alert_cooldown}

      not is_integer(claim_timeout_seconds) or claim_timeout_seconds < 1 ->
        {:error, :invalid_alert_claim_timeout}

      true ->
        :ok
    end
  end

  defp claim_alert(conn, fingerprint, attrs, now, cooldown_seconds, claim_timeout_seconds) do
    existing =
      query(
        conn,
        "SELECT status, claim_token, delivered_at FROM home_autonomy_alert_deliveries WHERE fingerprint = ?",
        [fingerprint]
      )

    suppressed_at =
      case existing do
        [[status, _token, delivered_at]] ->
          case DateTime.from_iso8601(delivered_at) do
            {:ok, recorded_at, _offset} ->
              age = max(0, DateTime.diff(now, recorded_at, :second))

              if (status == "completed" and age < cooldown_seconds) or
                   (status == "claimed" and age < claim_timeout_seconds),
                 do: delivered_at

            _ ->
              nil
          end

        _ ->
          nil
      end

    if suppressed_at do
      {:suppressed, suppressed_at}
    else
      token = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
      delivered_at = DateTime.to_iso8601(now)

      result =
        execute(
          conn,
          """
          INSERT INTO home_autonomy_alert_deliveries
            (fingerprint, issue_type, details_json, destination_fingerprint,
             status, claim_token, delivered_at)
          VALUES (?, ?, ?, ?, 'claimed', ?, ?)
          ON CONFLICT(fingerprint) DO UPDATE SET
            issue_type = excluded.issue_type,
            details_json = excluded.details_json,
            destination_fingerprint = excluded.destination_fingerprint,
            status = 'claimed',
            claim_token = excluded.claim_token,
            delivered_at = excluded.delivered_at
          """,
          [
            fingerprint,
            to_string(value(attrs, :issue_type)),
            Jason.encode!(json_safe(value(attrs, :details) || %{})),
            to_string(value(attrs, :destination_fingerprint)),
            token,
            delivered_at
          ]
        )

      case result do
        :ok ->
          case prune_alert_deliveries(conn, 1_000) do
            :ok -> {:ok, token}
            error -> error
          end

        error ->
          error
      end
    end
  end

  defp prune_alert_deliveries(conn, max_rows) do
    execute(
      conn,
      """
      DELETE FROM home_autonomy_alert_deliveries
      WHERE fingerprint IN (
        SELECT fingerprint FROM home_autonomy_alert_deliveries
        ORDER BY delivered_at DESC
        LIMIT -1 OFFSET ?
      )
      """,
      [max_rows]
    )
  end

  defp update_alert_claim(conn, fingerprint, token, status) do
    with [["claimed"]] <-
           query(
             conn,
             "SELECT status FROM home_autonomy_alert_deliveries WHERE fingerprint = ? AND claim_token = ?",
             [fingerprint, token]
           ),
         :ok <-
           execute(
             conn,
             "UPDATE home_autonomy_alert_deliveries SET status = ? WHERE fingerprint = ? AND claim_token = ?",
             [status, fingerprint, token]
           ) do
      :ok
    else
      [] -> {:error, :alert_claim_not_found}
      _ -> {:error, :alert_claim_not_active}
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

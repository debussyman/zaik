defmodule Zaik.Home.OccupancyTransitionStore do
  @moduledoc """
  Durable history of meaningful, area-scoped occupancy transitions.

  The store records the deterministic occupancy projection rather than every
  raw presence report. Cross-area entry sequences are exposed as observational
  co-occurrence only: they do not identify a person and cannot execute actions
  or override canonical occupancy.
  """

  use GenServer
  require Logger
  alias Exqlite.Sqlite3

  @statuses ~w(unknown occupied possibly_absent vacant)
  @transitions ~w(entered possibly_absent vacant)
  @retention 10_000

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put_new(server_opts, :name, __MODULE__))
  end

  def recent(area \\ nil, opts \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:recent, area, opts})

  def entry_sequences(opts \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:entry_sequences, opts})

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :db_path, Zaik.Home.HistoryStore.config().db_path) |> expand_path()
    unless path == ":memory:", do: path |> Path.dirname() |> File.mkdir_p!()

    with {:ok, conn} <- Sqlite3.open(path),
         :ok <- migrate(conn) do
      event_bus = Keyword.get(opts, :event_bus, Zaik.Home.EventBus)
      subscribe(event_bus)
      {:ok, %{conn: conn, event_bus: event_bus, clock: Keyword.get(opts, :clock)}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:zaik_home_event, %{type: :occupancy_changed} = event}, state) do
    case record_event(state.conn, event, state.clock) do
      result when result in [:ok, :ignored] ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to persist occupancy transition: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:recent, area, opts}, _from, state) do
    limit = opts |> Keyword.get(:limit, 100) |> bounded_limit()

    {where, params} =
      case normalize_optional(area) do
        nil -> {"", []}
        area -> {"WHERE area = ?", [area]}
      end

    rows =
      query(
        state.conn,
        select_sql("#{where} ORDER BY julianday(transitioned_at) DESC, id DESC LIMIT ?"),
        params ++ [limit]
      )
      |> Enum.map(&decode/1)

    {:reply, rows, state}
  end

  def handle_call({:entry_sequences, opts}, _from, state) do
    window_seconds = opts |> Keyword.get(:window_seconds, 300) |> bounded_window()
    limit = opts |> Keyword.get(:limit, 500) |> bounded_limit(500)

    entries =
      query(
        state.conn,
        select_sql(
          "WHERE transition = 'entered' ORDER BY julianday(transitioned_at) DESC, id DESC LIMIT ?"
        ),
        [limit]
      )
      |> Enum.map(&decode/1)
      |> Enum.reverse()

    sequences = summarize_sequences(entries, window_seconds)
    {:reply, sequences, state}
  end

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.conn)

  def migrate(conn) do
    Sqlite3.execute(conn, """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;

    CREATE TABLE IF NOT EXISTS home_occupancy_transitions (
      id TEXT PRIMARY KEY,
      area TEXT NOT NULL,
      previous_status TEXT NOT NULL,
      status TEXT NOT NULL,
      transition TEXT NOT NULL,
      confidence REAL NOT NULL,
      evidence_count INTEGER NOT NULL,
      observed_at TEXT,
      transitioned_at TEXT NOT NULL,
      recorded_at TEXT NOT NULL,
      source TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS home_occupancy_transitions_area_time_idx
      ON home_occupancy_transitions(area, transitioned_at DESC);
    CREATE INDEX IF NOT EXISTS home_occupancy_transitions_type_time_idx
      ON home_occupancy_transitions(transition, transitioned_at DESC);
    """)
  end

  defp record_event(_conn, %{previous_status: status, status: status}, _clock), do: :ignored

  defp record_event(_conn, %{transition: transition}, _clock)
       when transition not in @transitions,
       do: :ignored

  defp record_event(conn, event, clock) do
    area = normalize_optional(Map.get(event, :area))
    previous = event |> Map.get(:previous_status, "unknown") |> normalize()
    status = event |> Map.get(:status) |> normalize()
    transition = event |> Map.get(:transition) |> normalize()
    confidence = Map.get(event, :confidence)
    evidence_count = Map.get(event, :evidence_count, 0)
    observed_at = iso8601(Map.get(event, :observed_at))
    transitioned_at = iso8601(Map.get(event, :transitioned_at))
    recorded_at = clock |> Zaik.Time.now() |> DateTime.to_iso8601()

    with true <- is_binary(area) and area != "",
         true <- previous in @statuses,
         true <- status in @statuses,
         true <- transition in @transitions,
         true <- is_number(confidence) and confidence >= 0 and confidence <= 1,
         true <- is_integer(evidence_count) and evidence_count >= 0,
         true <- is_binary(transitioned_at) do
      id = transition_id(area, previous, status, transition, transitioned_at)

      execute(
        conn,
        """
        INSERT OR IGNORE INTO home_occupancy_transitions
          (id, area, previous_status, status, transition, confidence, evidence_count,
           observed_at, transitioned_at, recorded_at, source)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'occupancy_tracker')
        """,
        [
          id,
          area,
          previous,
          status,
          transition,
          confidence,
          evidence_count,
          observed_at,
          transitioned_at,
          recorded_at
        ]
      )
      |> then(fn
        :ok -> prune(conn)
        error -> error
      end)
    else
      _ -> {:error, :invalid_occupancy_transition}
    end
  end

  defp summarize_sequences(entries, window_seconds) do
    entries
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(%{}, fn [from, to], acc ->
      elapsed = seconds_between(from.transitioned_at, to.transitioned_at)

      if from.area != to.area and is_integer(elapsed) and elapsed >= 0 and
           elapsed <= window_seconds do
        key = {from.area, to.area}

        Map.update(
          acc,
          key,
          %{
            from_area: from.area,
            to_area: to.area,
            observations: 1,
            last_observed_at: to.transitioned_at,
            maximum_gap_seconds: elapsed,
            semantics: "observed_entry_sequence_not_person_identity"
          },
          fn summary ->
            %{
              summary
              | observations: summary.observations + 1,
                last_observed_at: to.transitioned_at,
                maximum_gap_seconds: max(summary.maximum_gap_seconds, elapsed)
            }
          end
        )
      else
        acc
      end
    end)
    |> Map.values()
    |> Enum.sort_by(&{-&1.observations, &1.from_area, &1.to_area})
  end

  defp seconds_between(from, to) do
    with {:ok, from, _} <- DateTime.from_iso8601(from),
         {:ok, to, _} <- DateTime.from_iso8601(to) do
      DateTime.diff(to, from, :second)
    else
      _ -> nil
    end
  end

  defp prune(conn) do
    execute(
      conn,
      """
      DELETE FROM home_occupancy_transitions
      WHERE id NOT IN (
        SELECT id FROM home_occupancy_transitions
        ORDER BY julianday(transitioned_at) DESC, id DESC LIMIT ?
      )
      """,
      [@retention]
    )
  end

  defp transition_id(area, previous, status, transition, transitioned_at) do
    {area, previous, status, transition, transitioned_at}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("occupancy_" <> String.slice(&1, 0, 24)))
  end

  defp select_sql(suffix) do
    """
    SELECT id, area, previous_status, status, transition, confidence, evidence_count,
           observed_at, transitioned_at, recorded_at, source
    FROM home_occupancy_transitions #{suffix}
    """
  end

  defp decode([
         id,
         area,
         previous_status,
         status,
         transition,
         confidence,
         evidence_count,
         observed_at,
         transitioned_at,
         recorded_at,
         source
       ]) do
    %{
      id: id,
      area: area,
      previous_status: previous_status,
      status: status,
      transition: transition,
      confidence: confidence,
      evidence_count: evidence_count,
      observed_at: observed_at,
      transitioned_at: transitioned_at,
      recorded_at: recorded_at,
      source: source
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
        with :ok <- Sqlite3.bind(statement, params),
             :done <- Sqlite3.step(conn, statement),
             do: :ok
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp subscribe(event_bus) when event_bus in [nil, false], do: :ok

  defp subscribe(event_bus) do
    if process_available?(event_bus), do: Zaik.Home.EventBus.subscribe(event_bus, self())
    :ok
  end

  defp process_available?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp process_available?(name) when is_atom(name), do: not is_nil(Process.whereis(name))
  defp process_available?(_), do: false

  defp bounded_limit(value, maximum \\ 500)
  defp bounded_limit(value, maximum) when is_integer(value), do: max(1, min(value, maximum))
  defp bounded_limit(_value, _maximum), do: 100
  defp bounded_window(value) when is_integer(value), do: max(1, min(value, 3_600))
  defp bounded_window(_value), do: 300
  defp normalize_optional(nil), do: nil
  defp normalize_optional(value), do: normalize(value)
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: nil
  defp expand_path(":memory:"), do: ":memory:"
  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)
end

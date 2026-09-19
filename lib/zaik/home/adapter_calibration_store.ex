defmodule Zaik.Home.AdapterCalibrationStore do
  @moduledoc """
  Durable per-entity/per-capability adapter calibration with append-only audit.

  Calibration is configuration evidence, not execution authority. Records do
  not rewrite canonical state or adapter payloads; consumers must explicitly
  opt into a supported versioned calibration kind.
  """

  use GenServer

  alias Exqlite.Sqlite3

  @schema_version 1
  @evidence_types ~w(operator_observation physical_measurement manufacturer_documentation)

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def config do
    configured = Application.get_env(:zaik, :adapter_calibrations, [])

    %{
      enabled:
        env_bool(
          "ZAIK_HOME_ADAPTER_CALIBRATIONS_ENABLED",
          Keyword.get(configured, :enabled, true)
        ),
      db_path:
        System.get_env("ZAIK_HOME_HISTORY_DB") ||
          System.get_env("ZAIK_HOME_ADAPTER_CALIBRATIONS_DB") ||
          Keyword.get(configured, :db_path, Zaik.Home.HistoryStore.config().db_path)
    }
  end

  def put(entity_id, capability, adapter, calibration, attrs, server \\ __MODULE__)
      when is_binary(entity_id) and is_binary(capability) and is_binary(adapter) and
             is_map(calibration) and is_map(attrs) do
    GenServer.call(server, {:put, entity_id, capability, adapter, calibration, attrs})
  end

  def get(entity_id, capability, adapter, server \\ __MODULE__) do
    GenServer.call(server, {:get, entity_id, capability, adapter})
  end

  def list(opts \\ [], server \\ __MODULE__) when is_list(opts) do
    GenServer.call(server, {:list, opts})
  end

  def history(entity_id, capability, adapter, server \\ __MODULE__) do
    GenServer.call(server, {:history, entity_id, capability, adapter})
  end

  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(opts) do
    cfg = Map.merge(config(), Map.new(opts))

    if cfg.enabled do
      db_path = expand_path(cfg.db_path)
      if db_path != ":memory:", do: File.mkdir_p!(Path.dirname(db_path))

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
  def handle_call({:put, _, _, _, _, _}, _from, %{conn: nil} = state),
    do: {:reply, {:error, :disabled}, state}

  def handle_call({:put, entity_id, capability, adapter, calibration, attrs}, _from, state) do
    {:reply, put_record(state.conn, entity_id, capability, adapter, calibration, attrs), state}
  end

  def handle_call({:get, _, _, _}, _from, %{conn: nil} = state),
    do: {:reply, {:error, :not_found}, state}

  def handle_call({:get, entity_id, capability, adapter}, _from, state) do
    {:reply, get_record(state.conn, entity_id, capability, adapter), state}
  end

  def handle_call({:list, _opts}, _from, %{conn: nil} = state), do: {:reply, [], state}

  def handle_call({:list, opts}, _from, state),
    do: {:reply, list_records(state.conn, opts), state}

  def handle_call({:history, _, _, _}, _from, %{conn: nil} = state),
    do: {:reply, [], state}

  def handle_call({:history, entity_id, capability, adapter}, _from, state) do
    {:reply, history_records(state.conn, entity_id, capability, adapter), state}
  end

  def handle_call(:reset, _from, %{conn: nil} = state), do: {:reply, :ok, state}

  def handle_call(:reset, _from, state) do
    :ok = Sqlite3.execute(state.conn, "DELETE FROM home_adapter_calibration_events;")
    :ok = Sqlite3.execute(state.conn, "DELETE FROM home_adapter_calibrations;")
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn), do: Sqlite3.close(conn)
  def terminate(_reason, _state), do: :ok

  def migrate(conn) do
    Sqlite3.execute(conn, """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;

    CREATE TABLE IF NOT EXISTS home_adapter_calibrations (
      entity_id TEXT NOT NULL,
      capability TEXT NOT NULL,
      adapter TEXT NOT NULL,
      schema_version INTEGER NOT NULL,
      revision INTEGER NOT NULL,
      kind TEXT NOT NULL,
      semantics_json TEXT NOT NULL,
      evidence_json TEXT NOT NULL,
      evidence_fingerprint TEXT NOT NULL,
      calibration_fingerprint TEXT NOT NULL,
      calibrated_by TEXT NOT NULL,
      reason TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY(entity_id, capability, adapter)
    );

    CREATE TABLE IF NOT EXISTS home_adapter_calibration_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      entity_id TEXT NOT NULL,
      capability TEXT NOT NULL,
      adapter TEXT NOT NULL,
      revision INTEGER NOT NULL,
      event_type TEXT NOT NULL,
      record_json TEXT NOT NULL,
      recorded_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS home_adapter_calibration_events_lookup_idx
      ON home_adapter_calibration_events(entity_id, capability, adapter, revision);
    """)
  end

  defp put_record(conn, entity_id, capability, adapter, calibration, attrs) do
    with {:ok, entity_id} <- non_empty(entity_id, :empty_entity_id),
         {:ok, capability} <- registered_capability(capability),
         {:ok, adapter} <- non_empty(adapter, :empty_adapter),
         {:ok, semantics} <- validate_calibration(capability, calibration),
         {:ok, evidence} <- validate_evidence(value(attrs, :evidence)),
         {:ok, calibrated_by} <- non_empty(value(attrs, :calibrated_by), :missing_calibrated_by),
         {:ok, reason} <- non_empty(value(attrs, :reason), :missing_calibration_reason) do
      existing = get_record(conn, entity_id, capability, adapter)
      revision = existing_revision(existing) + 1
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      created_at = existing_created_at(existing) || now
      evidence_fingerprint = fingerprint(evidence)

      calibration_fingerprint =
        fingerprint(%{
          schema_version: @schema_version,
          entity_id: entity_id,
          capability: capability,
          adapter: adapter,
          kind: semantics["kind"],
          semantics: semantics
        })

      record = %{
        "schema_version" => @schema_version,
        "entity_id" => entity_id,
        "capability" => capability,
        "adapter" => adapter,
        "revision" => revision,
        "kind" => semantics["kind"],
        "semantics" => semantics,
        "evidence" => evidence,
        "evidence_fingerprint" => evidence_fingerprint,
        "calibration_fingerprint" => calibration_fingerprint,
        "calibrated_by" => calibrated_by,
        "reason" => reason,
        "created_at" => created_at,
        "updated_at" => now
      }

      event_type = if revision == 1, do: "configured", else: "reconfigured"

      result =
        transaction(conn, fn ->
          with :ok <-
                 exec(
                   conn,
                   """
                   INSERT INTO home_adapter_calibrations (
                     entity_id, capability, adapter, schema_version, revision, kind, semantics_json,
                     evidence_json, evidence_fingerprint, calibration_fingerprint, calibrated_by,
                     reason, created_at, updated_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(entity_id, capability, adapter) DO UPDATE SET
                     schema_version = excluded.schema_version,
                     revision = excluded.revision,
                     kind = excluded.kind,
                     semantics_json = excluded.semantics_json,
                     evidence_json = excluded.evidence_json,
                     evidence_fingerprint = excluded.evidence_fingerprint,
                     calibration_fingerprint = excluded.calibration_fingerprint,
                     calibrated_by = excluded.calibrated_by,
                     reason = excluded.reason,
                     updated_at = excluded.updated_at
                   """,
                   [
                     entity_id,
                     capability,
                     adapter,
                     @schema_version,
                     revision,
                     semantics["kind"],
                     Jason.encode!(semantics),
                     Jason.encode!(evidence),
                     evidence_fingerprint,
                     calibration_fingerprint,
                     calibrated_by,
                     reason,
                     created_at,
                     now
                   ]
                 ),
               :ok <-
                 exec(
                   conn,
                   """
                   INSERT INTO home_adapter_calibration_events (
                     entity_id, capability, adapter, revision, event_type, record_json, recorded_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?)
                   """,
                   [
                     entity_id,
                     capability,
                     adapter,
                     revision,
                     event_type,
                     Jason.encode!(record),
                     now
                   ]
                 ) do
            :ok
          end
        end)

      case result do
        :ok -> {:ok, record}
        {:error, reason} -> {:error, {:calibration_persistence_failed, reason}}
      end
    end
  end

  defp get_record(conn, entity_id, capability, adapter) do
    case query(conn, select_sql() <> " WHERE entity_id = ? AND capability = ? AND adapter = ?", [
           String.trim(entity_id),
           normalize(capability),
           normalize(adapter)
         ]) do
      [row] -> {:ok, row_to_record(row)}
      [] -> {:error, :not_found}
    end
  end

  defp list_records(conn, opts) do
    filters = [
      entity_id: Keyword.get(opts, :entity_id),
      capability: Keyword.get(opts, :capability)
    ]

    {clauses, params} =
      Enum.reduce(filters, {[], []}, fn
        {_key, nil}, acc -> acc
        {_key, ""}, acc -> acc
        {key, val}, {cs, ps} -> {["#{key} = ?" | cs], [normalize_filter(key, val) | ps]}
      end)

    where = if clauses == [], do: "", else: " WHERE " <> Enum.join(Enum.reverse(clauses), " AND ")

    query(
      conn,
      select_sql() <> where <> " ORDER BY entity_id, capability, adapter",
      Enum.reverse(params)
    )
    |> Enum.map(&row_to_record/1)
  end

  defp history_records(conn, entity_id, capability, adapter) do
    query(
      conn,
      """
      SELECT record_json FROM home_adapter_calibration_events
      WHERE entity_id = ? AND capability = ? AND adapter = ?
      ORDER BY revision ASC
      """,
      [String.trim(entity_id), normalize(capability), normalize(adapter)]
    )
    |> Enum.map(fn [json] -> decode_json(json, %{}) end)
  end

  defp select_sql do
    """
    SELECT schema_version, entity_id, capability, adapter, revision, kind, semantics_json,
           evidence_json, evidence_fingerprint, calibration_fingerprint, calibrated_by,
           reason, created_at, updated_at
    FROM home_adapter_calibrations
    """
  end

  defp row_to_record([
         schema_version,
         entity_id,
         capability,
         adapter,
         revision,
         kind,
         semantics_json,
         evidence_json,
         evidence_fingerprint,
         calibration_fingerprint,
         calibrated_by,
         reason,
         created_at,
         updated_at
       ]) do
    %{
      "schema_version" => schema_version,
      "entity_id" => entity_id,
      "capability" => capability,
      "adapter" => adapter,
      "revision" => revision,
      "kind" => kind,
      "semantics" => decode_json(semantics_json, %{}),
      "evidence" => decode_json(evidence_json, []),
      "evidence_fingerprint" => evidence_fingerprint,
      "calibration_fingerprint" => calibration_fingerprint,
      "calibrated_by" => calibrated_by,
      "reason" => reason,
      "created_at" => created_at,
      "updated_at" => updated_at
    }
  end

  defp validate_calibration("cover", calibration) do
    kind = value(calibration, :kind) |> normalize()
    reported_open = value(calibration, :reported_open)
    reported_closed = value(calibration, :reported_closed)

    cond do
      kind != "cover_position_linear" ->
        {:error, {:unsupported_calibration_kind, "cover", kind}}

      not finite_number?(reported_open) or not finite_number?(reported_closed) ->
        {:error, :invalid_cover_calibration_endpoint}

      reported_open == reported_closed ->
        {:error, :degenerate_cover_calibration}

      true ->
        {:ok,
         %{
           "kind" => kind,
           "reported_open" => reported_open,
           "reported_closed" => reported_closed,
           "canonical_open" => 0,
           "canonical_closed" => 100
         }}
    end
  end

  defp validate_calibration(capability, calibration) do
    {:error, {:unsupported_calibration_kind, capability, value(calibration, :kind)}}
  end

  defp validate_evidence(evidence) when is_list(evidence) and evidence != [] do
    evidence
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      with true <- is_map(item),
           type when type in @evidence_types <- value(item, :type) |> normalize(),
           {:ok, reference} <- non_empty(value(item, :reference), :missing_evidence_reference),
           {:ok, observed_at} <- normalize_datetime(value(item, :observed_at)) do
        normalized = %{
          "type" => type,
          "reference" => reference,
          "observed_at" => observed_at
        }

        {:cont, {:ok, [normalized | acc]}}
      else
        false -> {:halt, {:error, :invalid_calibration_evidence}}
        type when is_binary(type) -> {:halt, {:error, {:unsupported_evidence_type, type}}}
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:halt, {:error, :invalid_calibration_evidence}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp validate_evidence(_), do: {:error, :missing_calibration_evidence}

  defp registered_capability(capability) do
    normalized = normalize(capability)

    case Zaik.Home.Capabilities.Registry.fetch(normalized) do
      {:ok, _module} -> {:ok, normalized}
      {:error, _reason} -> {:error, {:unknown_calibration_capability, normalized}}
    end
  end

  defp normalize_datetime(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_iso8601(datetime)}
      _ -> {:error, :invalid_evidence_observed_at}
    end
  end

  defp normalize_datetime(_value), do: {:error, :invalid_evidence_observed_at}

  defp transaction(conn, fun) do
    :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE;")

    try do
      case fun.() do
        :ok ->
          :ok = Sqlite3.execute(conn, "COMMIT;")
          :ok

        {:error, reason} ->
          Sqlite3.execute(conn, "ROLLBACK;")
          {:error, reason}
      end
    rescue
      error ->
        Sqlite3.execute(conn, "ROLLBACK;")
        reraise error, __STACKTRACE__
    end
  end

  defp exec(conn, sql, params) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql) do
      try do
        :ok = Sqlite3.bind(stmt, params)

        case Sqlite3.step(conn, stmt) do
          :done -> :ok
          {:error, reason} -> {:error, reason}
          :busy -> {:error, :busy}
          {:row, _row} -> :ok
        end
      after
        Sqlite3.release(conn, stmt)
      end
    end
  end

  defp query(conn, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)

    try do
      :ok = Sqlite3.bind(stmt, params)
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      rows
    after
      Sqlite3.release(conn, stmt)
    end
  end

  defp fingerprint(value) do
    value
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
  defp canonical(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical(value), do: value

  defp existing_revision({:ok, record}), do: record["revision"]
  defp existing_revision(_), do: 0
  defp existing_created_at({:ok, record}), do: record["created_at"]
  defp existing_created_at(_), do: nil

  defp non_empty(nil, error), do: {:error, error}

  defp non_empty(value, error) do
    normalized = value |> to_string() |> String.trim() |> String.replace(~r/\s+/, " ")
    if normalized == "", do: {:error, error}, else: {:ok, normalized}
  end

  defp finite_number?(value) when is_integer(value), do: true
  defp finite_number?(value) when is_float(value), do: value == value
  defp finite_number?(_value), do: false

  defp normalize_filter(:entity_id, value), do: String.trim(to_string(value))
  defp normalize_filter(_key, value), do: normalize(value)
  defp normalize(nil), do: ""
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp decode_json(json, default) do
    case Jason.decode(json) do
      {:ok, value} -> value
      _ -> default
    end
  end

  defp expand_path(":memory:"), do: ":memory:"
  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)

  defp env_bool(name, fallback) do
    case System.get_env(name) do
      nil -> fallback
      value -> value |> String.downcase() |> then(&(&1 in ["1", "true", "yes", "on"]))
    end
  end
end

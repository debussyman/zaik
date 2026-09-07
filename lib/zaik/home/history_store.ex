defmodule Zaik.Home.HistoryStore do
  @moduledoc """
  SQLite-backed telemetry history for home devices.

  The latest device state remains in `Zaik.Home.DeviceStore`; this store keeps
  structured historical readings suitable for trend and duration analysis.
  """

  use GenServer
  require Logger

  alias Exqlite.Sqlite3

  @history_capabilities %{
    "temperature" => {"temperature_c", :temperature},
    "temperature_c" => {"temperature_c", :temperature},
    "temperature_f" => {"temperature_c", :temperature},
    "humidity" => {"humidity", :humidity},
    "illuminance" => {"illuminance", :illuminance},
    "presence" => {"presence", :boolean},
    "pir_detection" => {"pir_detection", :boolean},
    "battery" => {"battery", :battery},
    "voltage" => {"voltage", :voltage},
    "linkquality" => {"linkquality", :linkquality},
    "target_distance" => {"target_distance", :target_distance}
  }

  @telemetry_keys %{
    temperature_c: "temperature",
    humidity: "humidity",
    illuminance: "illuminance",
    presence: "presence",
    pir_detection: "pir_detection",
    battery: "battery",
    voltage: "voltage",
    linkquality: "linkquality",
    target_distance: "target_distance"
  }

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def config do
    configured = Application.get_env(:zaik, :home_history, [])

    %{
      enabled: env_bool("ZAIK_HOME_HISTORY_ENABLED", Keyword.get(configured, :enabled, true)),
      db_path:
        System.get_env("ZAIK_HOME_HISTORY_DB") ||
          Keyword.get(configured, :db_path, "~/.zaik/home/home.db")
    }
  end

  def record_device(friendly_name, payload) when is_binary(friendly_name) and is_map(payload),
    do: record_device(__MODULE__, friendly_name, payload, %{}, [])

  def record_device(friendly_name, payload, metadata)
      when is_binary(friendly_name) and is_map(payload) and is_map(metadata),
      do: record_device(__MODULE__, friendly_name, payload, metadata, [])

  def record_device(friendly_name, payload, metadata, opts)
      when is_binary(friendly_name) and is_map(payload) and is_map(metadata) and is_list(opts),
      do: record_device(__MODULE__, friendly_name, payload, metadata, opts)

  def record_device(server, friendly_name, payload, metadata)
      when is_binary(friendly_name) and is_map(payload) and is_map(metadata),
      do: record_device(server, friendly_name, payload, metadata, [])

  def record_device(server, friendly_name, payload, metadata, opts)
      when is_binary(friendly_name) and is_map(payload) and is_map(metadata) and is_list(opts) do
    GenServer.call(server, {:record_device, friendly_name, payload, metadata, opts})
  end

  def list_devices(server \\ __MODULE__) do
    GenServer.call(server, :list_devices)
  end

  def configure_entity(device_query, area_id, aliases \\ [], server \\ __MODULE__)
      when is_binary(device_query) and is_list(aliases) do
    GenServer.call(server, {:configure_entity, device_query, area_id, aliases})
  end

  def recent_readings(friendly_name) when is_binary(friendly_name),
    do: recent_readings(__MODULE__, friendly_name, [])

  def recent_readings(friendly_name, opts) when is_binary(friendly_name) and is_list(opts),
    do: recent_readings(__MODULE__, friendly_name, opts)

  def recent_readings(server, friendly_name, opts)
      when is_binary(friendly_name) and is_list(opts) do
    GenServer.call(server, {:recent_readings, friendly_name, opts})
  end

  def readings_since(friendly_name, since)
      when is_binary(friendly_name) and is_struct(since, DateTime),
      do: readings_since(__MODULE__, friendly_name, since, [])

  def readings_since(friendly_name, since, opts)
      when is_binary(friendly_name) and is_struct(since, DateTime) and is_list(opts),
      do: readings_since(__MODULE__, friendly_name, since, opts)

  def readings_since(server, friendly_name, since)
      when is_binary(friendly_name) and is_struct(since, DateTime),
      do: readings_since(server, friendly_name, since, [])

  def readings_since(server, friendly_name, since, opts)
      when is_binary(friendly_name) and is_struct(since, DateTime) and is_list(opts) do
    GenServer.call(server, {:readings_since, friendly_name, since, opts})
  end

  def capability_history(query, capability, opts \\ [], server \\ __MODULE__)
      when is_binary(query) and is_list(opts) do
    GenServer.call(server, {:capability_history, query, capability, opts})
  end

  def count_readings, do: count_readings(__MODULE__, nil)

  def count_readings(friendly_name) when is_binary(friendly_name),
    do: count_readings(__MODULE__, friendly_name)

  def count_readings(server, friendly_name),
    do: GenServer.call(server, {:count_readings, friendly_name})

  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

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
  def handle_call(
        {:record_device, _friendly_name, _payload, _metadata, _opts},
        _from,
        %{conn: nil} = state
      ) do
    {:reply, :ignored, state}
  end

  def handle_call({:record_device, friendly_name, payload, metadata, opts}, _from, state) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    device_id = device_id(friendly_name, metadata)

    result =
      with :ok <- upsert_device(state.conn, device_id, friendly_name, metadata, observed_at),
           :ok <- insert_reading(state.conn, device_id, observed_at, payload) do
        :ok
      end

    {:reply, result, state}
  end

  def handle_call(:list_devices, _from, %{conn: nil} = state), do: {:reply, [], state}

  def handle_call(:list_devices, _from, state) do
    {:reply, query_devices(state.conn), state}
  end

  def handle_call({:configure_entity, _query, _area_id, _aliases}, _from, %{conn: nil} = state),
    do: {:reply, {:error, :disabled}, state}

  def handle_call({:configure_entity, device_query, area_id, aliases}, _from, state) do
    reply = configure_entity_row(state.conn, device_query, area_id, aliases)
    {:reply, reply, state}
  end

  def handle_call({:recent_readings, _friendly_name, _opts}, _from, %{conn: nil} = state) do
    {:reply, {:ok, []}, state}
  end

  def handle_call({:recent_readings, friendly_name, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 50)
    {:reply, {:ok, query_recent_readings(state.conn, friendly_name, limit)}, state}
  end

  def handle_call({:readings_since, _friendly_name, _since, _opts}, _from, %{conn: nil} = state) do
    {:reply, {:ok, []}, state}
  end

  def handle_call({:readings_since, friendly_name, since, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 500)
    {:reply, {:ok, query_readings_since(state.conn, friendly_name, since, limit)}, state}
  end

  def handle_call({:capability_history, _query, _capability, _opts}, _from, %{conn: nil} = state),
    do: {:reply, {:ok, []}, state}

  def handle_call({:capability_history, entity_query, capability, opts}, _from, state) do
    reply = query_capability_history(state.conn, entity_query, capability, opts)
    {:reply, reply, state}
  end

  def handle_call({:count_readings, _friendly_name}, _from, %{conn: nil} = state) do
    {:reply, 0, state}
  end

  def handle_call({:count_readings, friendly_name}, _from, state) do
    {:reply, count_readings_for(state.conn, friendly_name), state}
  end

  def handle_call(:reset, _from, %{conn: nil} = state), do: {:reply, :ok, state}

  def handle_call(:reset, _from, state) do
    :ok = Sqlite3.execute(state.conn, "DELETE FROM readings; DELETE FROM devices;")
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) do
    Sqlite3.close(conn)
    :ok
  end

  defp migrate(conn) do
    Sqlite3.execute(conn, """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    PRAGMA foreign_keys = ON;

    CREATE TABLE IF NOT EXISTS devices (
      id TEXT PRIMARY KEY,
      friendly_name TEXT NOT NULL,
      area_id TEXT,
      source TEXT,
      topic TEXT,
      metadata_json TEXT NOT NULL DEFAULT '{}',
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS readings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      device_id TEXT NOT NULL,
      observed_at TEXT NOT NULL,
      temperature_c REAL,
      humidity REAL,
      illuminance REAL,
      presence INTEGER,
      pir_detection INTEGER,
      battery REAL,
      voltage REAL,
      linkquality REAL,
      target_distance REAL,
      payload_json TEXT NOT NULL,
      provenance TEXT NOT NULL DEFAULT 'observed',
      FOREIGN KEY(device_id) REFERENCES devices(id)
    );

    CREATE INDEX IF NOT EXISTS readings_device_time_idx
      ON readings(device_id, observed_at);

    CREATE INDEX IF NOT EXISTS readings_time_idx
      ON readings(observed_at);

    CREATE TABLE IF NOT EXISTS home_entity_aliases (
      device_id TEXT NOT NULL,
      alias TEXT NOT NULL COLLATE NOCASE,
      created_at TEXT NOT NULL,
      PRIMARY KEY(device_id, alias),
      FOREIGN KEY(device_id) REFERENCES devices(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS home_entity_aliases_alias_idx
      ON home_entity_aliases(alias);

    CREATE TABLE IF NOT EXISTS home_device_preset_rows (
      device_key TEXT NOT NULL,
      preset_key TEXT NOT NULL,
      capability TEXT NOT NULL,
      device_name TEXT NOT NULL,
      preset_name TEXT NOT NULL,
      target_json TEXT NOT NULL,
      source TEXT,
      created_by TEXT,
      metadata_json TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY(device_key, preset_key, capability)
    );

    CREATE INDEX IF NOT EXISTS home_device_preset_device_idx
      ON home_device_preset_rows(device_key, capability);

    CREATE VIEW IF NOT EXISTS home_device_presets AS
      SELECT device_name,
             preset_name,
             capability,
             target_json,
             source,
             created_by,
             metadata_json,
             created_at,
             updated_at
      FROM home_device_preset_rows;
    """)
    |> case do
      :ok ->
        with :ok <- ensure_column(conn, "devices", "area_id", "TEXT"),
             :ok <-
               ensure_column(
                 conn,
                 "readings",
                 "provenance",
                 "TEXT NOT NULL DEFAULT 'legacy_unknown'"
               ) do
          recreate_home_views(conn)
        end

      error ->
        error
    end
  end

  defp ensure_column(conn, table, column, definition) do
    existing = query(conn, "PRAGMA table_info(#{table})") |> Enum.map(&Enum.at(&1, 1))

    if column in existing do
      :ok
    else
      Sqlite3.execute(conn, "ALTER TABLE #{table} ADD COLUMN #{column} #{definition}")
    end
  end

  defp recreate_home_views(conn) do
    Sqlite3.execute(conn, """
    DROP VIEW IF EXISTS home_devices;
    DROP VIEW IF EXISTS home_readings;

    CREATE VIEW home_devices AS
      SELECT id, friendly_name, area_id, source, topic, metadata_json, inserted_at, updated_at
      FROM devices;

    CREATE VIEW home_readings AS
      SELECT r.id,
             r.device_id,
             d.friendly_name AS device_name,
             COALESCE(d.area_id, d.friendly_name) AS room,
             d.area_id,
             r.observed_at AS recorded_at,
             r.temperature_c,
             CASE
               WHEN r.temperature_c IS NULL THEN NULL
               ELSE r.temperature_c * 9.0 / 5.0 + 32.0
             END AS temperature_f,
             r.humidity,
             r.illuminance,
             r.presence,
             r.pir_detection,
             r.battery,
             r.voltage,
             r.linkquality,
             r.target_distance,
             r.provenance,
             r.payload_json
      FROM readings r
      JOIN devices d ON d.id = r.device_id;
    """)
  end

  defp upsert_device(conn, device_id, friendly_name, metadata, observed_at) do
    now = DateTime.to_iso8601(observed_at)

    exec(
      conn,
      """
      INSERT INTO devices (id, friendly_name, area_id, source, topic, metadata_json, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        friendly_name = excluded.friendly_name,
        area_id = COALESCE(devices.area_id, excluded.area_id),
        source = excluded.source,
        topic = excluded.topic,
        metadata_json = excluded.metadata_json,
        updated_at = excluded.updated_at
      """,
      [
        device_id,
        friendly_name,
        metadata["area_id"] || metadata[:area_id] || metadata["area"] || metadata[:area] ||
          metadata["room"] || metadata[:room],
        metadata["source"] || metadata[:source],
        metadata["topic"] || metadata[:topic],
        Jason.encode!(metadata),
        now,
        now
      ]
    )
  end

  defp insert_reading(conn, device_id, observed_at, payload) do
    exec(
      conn,
      """
      INSERT INTO readings (
        device_id, observed_at, temperature_c, humidity, illuminance, presence,
        pir_detection, battery, voltage, linkquality, target_distance, payload_json, provenance
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        device_id,
        DateTime.to_iso8601(observed_at),
        numeric(payload[@telemetry_keys.temperature_c]),
        numeric(payload[@telemetry_keys.humidity]),
        numeric(payload[@telemetry_keys.illuminance]),
        boolean_integer(payload[@telemetry_keys.presence]),
        boolean_integer(payload[@telemetry_keys.pir_detection]),
        numeric(payload[@telemetry_keys.battery]),
        numeric(payload[@telemetry_keys.voltage]),
        numeric(payload[@telemetry_keys.linkquality]),
        numeric(payload[@telemetry_keys.target_distance]),
        Jason.encode!(payload),
        "observed"
      ]
    )
  end

  defp configure_entity_row(conn, device_query, area_id, aliases) do
    query_key = normalize(device_query)

    matches =
      conn
      |> query_devices()
      |> Enum.filter(fn device ->
        normalize(device.id) == query_key or normalize(device.friendly_name) == query_key or
          query_key in Enum.map(device.aliases, &normalize/1) or
          String.contains?(normalize(device.friendly_name), query_key)
      end)

    case matches do
      [device] ->
        area_id = normalize_optional(area_id)

        aliases =
          aliases
          |> Enum.map(&String.trim(to_string(&1)))
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq_by(&normalize/1)

        now = DateTime.utc_now() |> DateTime.to_iso8601()

        with :ok <- exec(conn, "BEGIN IMMEDIATE", []),
             :ok <-
               exec(conn, "UPDATE devices SET area_id = ?, updated_at = ? WHERE id = ?", [
                 area_id,
                 now,
                 device.id
               ]),
             :ok <-
               exec(conn, "DELETE FROM home_entity_aliases WHERE device_id = ?", [device.id]),
             :ok <- insert_aliases(conn, device.id, aliases, now),
             :ok <- exec(conn, "COMMIT", []) do
          {:ok,
           %{device_id: device.id, name: device.friendly_name, area_id: area_id, aliases: aliases}}
        else
          {:error, reason} ->
            _ = exec(conn, "ROLLBACK", [])
            {:error, reason}
        end

      [] ->
        {:error, :not_found}

      devices ->
        {:error, {:ambiguous, Enum.map(devices, & &1.friendly_name)}}
    end
  end

  defp insert_aliases(conn, device_id, aliases, now) do
    Enum.reduce_while(aliases, :ok, fn alias_name, :ok ->
      case exec(
             conn,
             "INSERT INTO home_entity_aliases (device_id, alias, created_at) VALUES (?, ?, ?)",
             [device_id, alias_name, now]
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp query_aliases(conn, device_id) do
    query(
      conn,
      "SELECT alias FROM home_entity_aliases WHERE device_id = ? ORDER BY alias COLLATE NOCASE",
      [device_id]
    )
    |> Enum.map(&hd/1)
  end

  defp query_devices(conn) do
    query(conn, """
    SELECT id, friendly_name, area_id, source, topic, metadata_json, inserted_at, updated_at
    FROM devices
    ORDER BY friendly_name COLLATE NOCASE
    """)
    |> Enum.map(fn [
                     id,
                     friendly_name,
                     area_id,
                     source,
                     topic,
                     metadata_json,
                     inserted_at,
                     updated_at
                   ] ->
      %{
        id: id,
        friendly_name: friendly_name,
        area_id: area_id,
        aliases: query_aliases(conn, id),
        source: source,
        topic: topic,
        metadata: decode_json(metadata_json, %{}),
        inserted_at: parse_datetime(inserted_at),
        updated_at: parse_datetime(updated_at)
      }
    end)
  end

  defp query_recent_readings(conn, friendly_name, limit) do
    query_readings(
      conn,
      """
      SELECT r.id, r.device_id, d.friendly_name, r.observed_at, r.temperature_c, r.humidity,
             r.illuminance, r.presence, r.pir_detection, r.battery, r.voltage,
             r.linkquality, r.target_distance, r.payload_json, r.provenance
      FROM readings r
      JOIN devices d ON d.id = r.device_id
      WHERE lower(d.friendly_name) = lower(?) OR lower(d.friendly_name) LIKE lower(?)
      ORDER BY r.observed_at DESC
      LIMIT ?
      """,
      [friendly_name, "%#{friendly_name}%", limit]
    )
    |> Enum.reverse()
  end

  defp query_readings_since(conn, friendly_name, since, limit) do
    query_readings(
      conn,
      """
      SELECT r.id, r.device_id, d.friendly_name, r.observed_at, r.temperature_c, r.humidity,
             r.illuminance, r.presence, r.pir_detection, r.battery, r.voltage,
             r.linkquality, r.target_distance, r.payload_json, r.provenance
      FROM readings r
      JOIN devices d ON d.id = r.device_id
      WHERE (lower(d.friendly_name) = lower(?) OR lower(d.friendly_name) LIKE lower(?))
        AND r.observed_at >= ?
      ORDER BY r.observed_at ASC
      LIMIT ?
      """,
      [friendly_name, "%#{friendly_name}%", DateTime.to_iso8601(since), limit]
    )
  end

  defp query_readings(conn, sql, params) do
    query(conn, sql, params)
    |> Enum.map(fn [
                     id,
                     device_id,
                     friendly_name,
                     observed_at,
                     temperature_c,
                     humidity,
                     illuminance,
                     presence,
                     pir_detection,
                     battery,
                     voltage,
                     linkquality,
                     target_distance,
                     payload_json,
                     provenance
                   ] ->
      %{
        id: id,
        device_id: device_id,
        friendly_name: friendly_name,
        observed_at: parse_datetime(observed_at),
        temperature_c: temperature_c,
        temperature_f: celsius_to_fahrenheit(temperature_c),
        humidity: humidity,
        illuminance: illuminance,
        presence: integer_boolean(presence),
        pir_detection: integer_boolean(pir_detection),
        battery: battery,
        voltage: voltage,
        linkquality: linkquality,
        target_distance: target_distance,
        payload: decode_json(payload_json, %{}),
        provenance: provenance
      }
    end)
  end

  defp query_capability_history(conn, entity_query, capability, opts) do
    capability = capability |> to_string() |> String.downcase()

    case Map.fetch(@history_capabilities, capability) do
      {:ok, {column, type}} ->
        limit = opts |> Keyword.get(:limit, 100) |> clamp_limit()
        from = Keyword.get(opts, :from)
        until_time = Keyword.get(opts, :until)
        {time_sql, time_params} = history_time_filter(from, until_time)
        like_query = "%#{entity_query}%"

        rows =
          query(
            conn,
            """
            SELECT d.id, d.friendly_name, d.area_id, r.observed_at, r.#{column}, r.provenance
            FROM readings r
            JOIN devices d ON d.id = r.device_id
            WHERE (
              lower(d.id) = lower(?) OR
              lower(d.friendly_name) = lower(?) OR
              lower(d.friendly_name) LIKE lower(?) OR
              lower(COALESCE(d.area_id, '')) = lower(?) OR
              EXISTS (
                SELECT 1 FROM home_entity_aliases a
                WHERE a.device_id = d.id AND lower(a.alias) = lower(?)
              )
            )
              AND r.#{column} IS NOT NULL
              #{time_sql}
            ORDER BY r.observed_at ASC
            LIMIT ?
            """,
            [entity_query, entity_query, like_query, entity_query, entity_query] ++
              time_params ++ [limit]
          )
          |> Enum.map(fn [device_id, name, area_id, observed_at, value, provenance] ->
            %{
              device_id: device_id,
              device: name,
              area_id: area_id,
              capability: capability,
              value: history_value(type, capability, value),
              observed_at: observed_at,
              provenance: provenance
            }
          end)

        {:ok, rows}

      :error ->
        {:error, {:unsupported_capability, capability}}
    end
  end

  defp history_time_filter(from, until_time) do
    filters =
      []
      |> maybe_time_filter("r.observed_at >= ?", from)
      |> maybe_time_filter("r.observed_at <= ?", until_time)

    case filters do
      [] ->
        {"", []}

      filters ->
        {"AND " <> Enum.map_join(filters, " AND ", &elem(&1, 0)), Enum.map(filters, &elem(&1, 1))}
    end
  end

  defp maybe_time_filter(filters, _sql, nil), do: filters

  defp maybe_time_filter(filters, sql, %DateTime{} = datetime),
    do: filters ++ [{sql, DateTime.to_iso8601(datetime)}]

  defp maybe_time_filter(filters, sql, value) when is_binary(value),
    do: filters ++ [{sql, value}]

  defp maybe_time_filter(filters, _sql, _value), do: filters

  defp history_value(:temperature, "temperature_f", value),
    do: %{fahrenheit: celsius_to_fahrenheit(value), celsius: value}

  defp history_value(:temperature, _capability, value),
    do: %{celsius: value, fahrenheit: celsius_to_fahrenheit(value)}

  defp history_value(:boolean, _capability, value), do: integer_boolean(value)
  defp history_value(_type, _capability, value), do: value

  defp clamp_limit(value) when is_integer(value), do: value |> max(1) |> min(500)
  defp clamp_limit(_value), do: 100

  defp count_readings_for(conn, nil) do
    [[count]] = query(conn, "SELECT COUNT(*) FROM readings")
    count
  end

  defp count_readings_for(conn, friendly_name) do
    [[count]] =
      query(
        conn,
        """
        SELECT COUNT(*)
        FROM readings r
        JOIN devices d ON d.id = r.device_id
        WHERE lower(d.friendly_name) = lower(?) OR lower(d.friendly_name) LIKE lower(?)
        """,
        [friendly_name, "%#{friendly_name}%"]
      )

    count
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

  defp query(conn, sql, params \\ []) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)

    try do
      :ok = Sqlite3.bind(stmt, params)
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      rows
    after
      Sqlite3.release(conn, stmt)
    end
  end

  defp device_id(friendly_name, metadata) do
    metadata["ieee_address"] || metadata[:ieee_address] || metadata["topic"] || metadata[:topic] ||
      normalize(friendly_name)
  end

  defp numeric(value) when is_integer(value) or is_float(value), do: value

  defp numeric(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp numeric(_value), do: nil

  defp boolean_integer(true), do: 1
  defp boolean_integer(false), do: 0
  defp boolean_integer(1), do: 1
  defp boolean_integer(0), do: 0
  defp boolean_integer(_value), do: nil

  defp integer_boolean(1), do: true
  defp integer_boolean(0), do: false
  defp integer_boolean(nil), do: nil

  defp celsius_to_fahrenheit(nil), do: nil
  defp celsius_to_fahrenheit(celsius), do: celsius * 9 / 5 + 32

  defp decode_json(nil, default), do: default

  defp decode_json(json, default) do
    case Jason.decode(json) do
      {:ok, decoded} -> decoded
      {:error, _error} -> default
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> value
    end
  end

  defp normalize_optional(nil), do: nil

  defp normalize_optional(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      value -> value
    end
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

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

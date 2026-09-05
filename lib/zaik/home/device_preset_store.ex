defmodule Zaik.Home.DevicePresetStore do
  @moduledoc """
  SQLite-backed named target store for home devices.

  Presets are generic: a preset is a remembered target shape for a device
  capability, e.g. `{device, "above AC", "cover", %{"position" => 71}}`.
  Device-specific modules still validate and execute the target.
  """

  use GenServer

  alias Exqlite.Sqlite3

  @legacy_blind_presets_path "~/.zaik/home/blind_presets.json"

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def config do
    configured = Application.get_env(:zaik, :device_presets, [])

    %{
      enabled: env_bool("ZAIK_DEVICE_PRESETS_ENABLED", Keyword.get(configured, :enabled, true)),
      db_path:
        System.get_env("ZAIK_HOME_HISTORY_DB") ||
          System.get_env("ZAIK_DEVICE_PRESETS_DB") ||
          Keyword.get(configured, :db_path, Zaik.Home.HistoryStore.config().db_path),
      import_legacy_blind_presets?:
        env_bool(
          "ZAIK_IMPORT_LEGACY_BLIND_PRESETS",
          Keyword.get(configured, :import_legacy_blind_presets?, true)
        ),
      legacy_blind_presets_path:
        System.get_env("ZAIK_LEGACY_BLIND_PRESETS_PATH") ||
          Keyword.get(configured, :legacy_blind_presets_path, @legacy_blind_presets_path)
    }
  end

  def put(device_name, preset_name, capability, target, attrs \\ %{}, server \\ __MODULE__)
      when is_binary(device_name) and is_binary(preset_name) and is_binary(capability) and
             is_map(target) and is_map(attrs) do
    GenServer.call(server, {:put, device_name, preset_name, capability, target, attrs})
  end

  def get(device_name, preset_name, opts \\ [], server \\ __MODULE__)
      when is_binary(device_name) and is_binary(preset_name) and is_list(opts) do
    GenServer.call(server, {:get, device_name, preset_name, opts})
  end

  def list(device_name \\ nil, opts \\ [], server \\ __MODULE__) when is_list(opts) do
    GenServer.call(server, {:list, device_name, opts})
  end

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
        state = %{conn: conn, config: cfg}
        maybe_import_legacy_blind_presets(state)
        {:ok, state}
      else
        {:error, reason} -> {:stop, reason}
      end
    else
      {:ok, %{conn: nil, config: cfg}}
    end
  end

  @impl true
  def handle_call(
        {:put, _device_name, _preset_name, _capability, _target, _attrs},
        _from,
        %{conn: nil} = state
      ) do
    {:reply, :ignored, state}
  end

  def handle_call({:put, device_name, preset_name, capability, target, attrs}, _from, state) do
    result = put_preset(state.conn, device_name, preset_name, capability, target, attrs)
    {:reply, result, state}
  end

  def handle_call({:get, _device_name, _preset_name, _opts}, _from, %{conn: nil} = state) do
    {:reply, {:error, :not_found}, state}
  end

  def handle_call({:get, device_name, preset_name, opts}, _from, state) do
    {:reply, get_preset(state.conn, device_name, preset_name, opts), state}
  end

  def handle_call({:list, _device_name, _opts}, _from, %{conn: nil} = state) do
    {:reply, [], state}
  end

  def handle_call({:list, device_name, opts}, _from, state) do
    {:reply, list_presets(state.conn, device_name, opts), state}
  end

  def handle_call(:reset, _from, %{conn: nil} = state), do: {:reply, :ok, state}

  def handle_call(:reset, _from, state) do
    :ok = Sqlite3.execute(state.conn, "DELETE FROM home_device_preset_rows;")
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn) do
    Sqlite3.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  def migrate(conn) do
    Sqlite3.execute(conn, """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;

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
  end

  defp put_preset(conn, device_name, preset_name, capability, target, attrs) do
    with {:ok, preset_name} <- non_empty(preset_name, :empty_preset_name),
         {:ok, capability} <- non_empty(capability, :empty_capability),
         :ok <- validate_target(target) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      existing = get_preset(conn, device_name, preset_name, capability: capability)

      created_at =
        existing_created_at(existing) || Map.get(attrs, :created_at) ||
          Map.get(attrs, "created_at") || now

      params = [
        normalize_key(device_name),
        normalize_key(preset_name),
        capability,
        String.trim(device_name),
        preset_name,
        Jason.encode!(target),
        Map.get(attrs, :source) || Map.get(attrs, "source") || "manual",
        maybe_string(Map.get(attrs, :created_by) || Map.get(attrs, "created_by")),
        Jason.encode!(Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}),
        created_at,
        now
      ]

      :ok =
        exec(
          conn,
          """
          INSERT INTO home_device_preset_rows (
            device_key, preset_key, capability, device_name, preset_name, target_json,
            source, created_by, metadata_json, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(device_key, preset_key, capability) DO UPDATE SET
            device_name = excluded.device_name,
            preset_name = excluded.preset_name,
            target_json = excluded.target_json,
            source = excluded.source,
            created_by = excluded.created_by,
            metadata_json = excluded.metadata_json,
            updated_at = excluded.updated_at
          """,
          params
        )

      get_preset(conn, device_name, preset_name, capability: capability)
    end
  end

  defp get_preset(conn, device_name, preset_name, opts) do
    capability = Keyword.get(opts, :capability)

    rows =
      if is_binary(capability) do
        query(
          conn,
          """
          SELECT device_name, preset_name, capability, target_json, source, created_by,
                 metadata_json, created_at, updated_at
          FROM home_device_preset_rows
          WHERE device_key = ? AND preset_key = ? AND capability = ?
          ORDER BY preset_name COLLATE NOCASE
          """,
          [normalize_key(device_name), normalize_key(preset_name), capability]
        )
      else
        query(
          conn,
          """
          SELECT device_name, preset_name, capability, target_json, source, created_by,
                 metadata_json, created_at, updated_at
          FROM home_device_preset_rows
          WHERE device_key = ? AND preset_key = ?
          ORDER BY preset_name COLLATE NOCASE
          """,
          [normalize_key(device_name), normalize_key(preset_name)]
        )
      end
      |> Enum.map(&row_to_preset/1)

    case rows do
      [preset] -> {:ok, preset}
      [] -> {:error, :not_found}
      presets -> {:error, {:ambiguous, Enum.map(presets, & &1["capability"])}}
    end
  end

  defp list_presets(conn, device_name, opts) do
    capability = Keyword.get(opts, :capability)

    {where, params} = list_where(device_name, capability)

    query(
      conn,
      """
      SELECT device_name, preset_name, capability, target_json, source, created_by,
             metadata_json, created_at, updated_at
      FROM home_device_preset_rows
      #{where}
      ORDER BY device_name COLLATE NOCASE, preset_name COLLATE NOCASE, capability COLLATE NOCASE
      """,
      params
    )
    |> Enum.map(&row_to_preset/1)
  end

  defp list_where(nil, nil), do: {"", []}
  defp list_where("", nil), do: {"", []}

  defp list_where(nil, capability) when is_binary(capability),
    do: {"WHERE capability = ?", [capability]}

  defp list_where("", capability) when is_binary(capability),
    do: {"WHERE capability = ?", [capability]}

  defp list_where(device_name, nil),
    do: {"WHERE device_key = ?", [normalize_key(device_name)]}

  defp list_where(device_name, capability),
    do: {"WHERE device_key = ? AND capability = ?", [normalize_key(device_name), capability]}

  defp maybe_import_legacy_blind_presets(%{config: %{import_legacy_blind_presets?: false}}),
    do: :ok

  defp maybe_import_legacy_blind_presets(%{conn: nil}), do: :ok

  defp maybe_import_legacy_blind_presets(%{conn: conn, config: cfg}) do
    path = expand_path(cfg.legacy_blind_presets_path)

    with {:ok, contents} <- File.read(path),
         {:ok, presets} when is_list(presets) <- Jason.decode(contents) do
      Enum.each(presets, fn preset ->
        with device_name when is_binary(device_name) <- preset["device_name"],
             preset_name when is_binary(preset_name) <- preset["preset_name"],
             {:ok, position} <- normalize_position(preset["position"]),
             {:error, :not_found} <-
               get_preset(conn, device_name, preset_name, capability: "cover") do
          put_preset(
            conn,
            device_name,
            preset_name,
            "cover",
            %{"position" => position},
            %{
              source: preset["source"] || "legacy_blind_import",
              created_by: preset["created_by"],
              created_at: preset["created_at"],
              metadata:
                Map.merge(preset["metadata"] || %{}, %{"legacy_store" => "blind_presets.json"})
            }
          )
        else
          _ -> :ok
        end
      end)
    else
      _ -> :ok
    end
  end

  defp row_to_preset([
         device_name,
         preset_name,
         capability,
         target_json,
         source,
         created_by,
         metadata_json,
         created_at,
         updated_at
       ]) do
    %{
      "device_name" => device_name,
      "preset_name" => preset_name,
      "capability" => capability,
      "target" => decode_json(target_json, %{}),
      "target_json" => target_json,
      "source" => source,
      "created_by" => created_by,
      "metadata" => decode_json(metadata_json, %{}),
      "metadata_json" => metadata_json,
      "created_at" => created_at,
      "updated_at" => updated_at
    }
  end

  defp validate_target(target) when map_size(target) > 0, do: :ok
  defp validate_target(_target), do: {:error, :empty_target}

  defp non_empty(value, error) do
    value = value |> to_string() |> String.trim() |> String.replace(~r/\s+/, " ")
    if value == "", do: {:error, error}, else: {:ok, value}
  end

  defp existing_created_at({:ok, preset}), do: preset["created_at"]
  defp existing_created_at(_), do: nil

  defp normalize_position(value) when is_integer(value) and value in 0..100, do: {:ok, value}

  defp normalize_position(value) when is_float(value),
    do: value |> round() |> normalize_position()

  defp normalize_position(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> normalize_position(int)
      _ -> {:error, :invalid_position}
    end
  end

  defp normalize_position(_value), do: {:error, :invalid_position}

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

  defp decode_json(nil, default), do: default

  defp decode_json(json, default) do
    case Jason.decode(json) do
      {:ok, decoded} -> decoded
      {:error, _error} -> default
    end
  end

  defp normalize_key(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/['’]/, "")
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp maybe_string(nil), do: nil
  defp maybe_string(value), do: to_string(value)

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

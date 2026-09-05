defmodule Zaik.Home.ActionLedger do
  @moduledoc """
  Persistent request-scoped idempotency ledger for home actions.

  The ledger does not execute actions. It atomically claims a semantic action
  before execution and stores the terminal result afterward. Reprocessing the
  same ingress message and action returns the recorded result instead of
  invoking the adapter again.
  """

  use GenServer
  alias Exqlite.Sqlite3

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def config do
    configured = Application.get_env(:zaik, :home_action_ledger, [])
    history = Zaik.Home.HistoryStore.config()

    %{
      enabled: Keyword.get(configured, :enabled, true),
      db_path: Keyword.get(configured, :db_path, history.db_path)
    }
  end

  def claim(tool, args, context, server \\ __MODULE__) do
    case idempotency_key(tool, args, context) do
      nil -> {:ok, nil}
      key -> GenServer.call(server, {:claim, key, request_key(context), to_string(tool), args})
    end
  end

  def complete(key, result, server \\ __MODULE__)

  def complete(nil, _result, _server), do: :ok

  def complete(key, result, server) when is_binary(key) do
    GenServer.call(server, {:complete, key, result})
  end

  def lookup(key, server \\ __MODULE__) when is_binary(key),
    do: GenServer.call(server, {:lookup, key})

  def idempotency_key(tool, args, context) when is_map(args) and is_map(context) do
    case request_key(context) do
      nil ->
        nil

      request_key ->
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary({request_key, to_string(tool), canonical(args)})
        )
        |> Base.encode16(case: :lower)
    end
  end

  @impl true
  def init(opts) do
    cfg = Map.merge(config(), Map.new(opts))

    if cfg.enabled do
      path = expand_path(cfg.db_path)
      unless path == ":memory:", do: path |> Path.dirname() |> File.mkdir_p!()

      with {:ok, conn} <- Sqlite3.open(path),
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
  def handle_call({:claim, _key, _request_key, _tool, _args}, _from, %{conn: nil} = state),
    do: {:reply, {:ok, nil}, state}

  def handle_call({:claim, key, request_key, tool, args}, _from, state) do
    reply =
      case fetch(state.conn, key) do
        nil ->
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          case exec(
                 state.conn,
                 "INSERT INTO home_action_ledger (idempotency_key, request_key, tool, args_json, status, inserted_at, updated_at) VALUES (?, ?, ?, ?, 'running', ?, ?)",
                 [key, request_key, tool, Jason.encode!(args), now, now]
               ) do
            :ok -> {:ok, key}
            {:error, reason} -> {:error, reason}
          end

        entry ->
          {:duplicate, duplicate_result(entry)}
      end

    {:reply, reply, state}
  end

  def handle_call({:complete, _key, _result}, _from, %{conn: nil} = state),
    do: {:reply, :ok, state}

  def handle_call({:complete, key, result}, _from, state) do
    {status, result_json, error_json} = encoded_result(result)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    reply =
      exec(
        state.conn,
        "UPDATE home_action_ledger SET status = ?, result_json = ?, error_json = ?, updated_at = ? WHERE idempotency_key = ?",
        [status, result_json, error_json, now, key]
      )

    {:reply, reply, state}
  end

  def handle_call({:lookup, _key}, _from, %{conn: nil} = state),
    do: {:reply, {:error, :disabled}, state}

  def handle_call({:lookup, key}, _from, state) do
    case fetch(state.conn, key) do
      nil -> {:reply, {:error, :not_found}, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  @impl true
  def terminate(_reason, %{conn: nil}), do: :ok
  def terminate(_reason, %{conn: conn}), do: Sqlite3.close(conn)

  defp migrate(conn) do
    Sqlite3.execute(conn, """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;

    CREATE TABLE IF NOT EXISTS home_action_ledger (
      idempotency_key TEXT PRIMARY KEY,
      request_key TEXT NOT NULL,
      tool TEXT NOT NULL,
      args_json TEXT NOT NULL,
      status TEXT NOT NULL,
      result_json TEXT,
      error_json TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS home_action_ledger_request_idx
      ON home_action_ledger(request_key, inserted_at);
    """)
  end

  defp fetch(conn, key) do
    case query(
           conn,
           "SELECT idempotency_key, request_key, tool, args_json, status, result_json, error_json, inserted_at, updated_at FROM home_action_ledger WHERE idempotency_key = ?",
           [key]
         ) do
      [] ->
        nil

      [
        [
          idempotency_key,
          request_key,
          tool,
          args_json,
          status,
          result_json,
          error_json,
          inserted_at,
          updated_at
        ]
      ] ->
        %{
          idempotency_key: idempotency_key,
          request_key: request_key,
          tool: tool,
          args: decode(args_json),
          status: status,
          result: decode(result_json),
          error: decode(error_json),
          inserted_at: inserted_at,
          updated_at: updated_at
        }
    end
  end

  defp duplicate_result(%{status: "succeeded", result: result}) when is_map(result),
    do: {:ok, Map.merge(result, %{"duplicate" => true, "status" => "duplicate_suppressed"})}

  defp duplicate_result(%{status: "succeeded", result: result}), do: {:ok, result}
  defp duplicate_result(%{status: "running"}), do: {:error, :action_already_in_progress}

  defp duplicate_result(%{status: "failed", error: error}),
    do: {:error, {:previous_action_failed, error}}

  defp duplicate_result(entry), do: {:error, {:unknown_previous_action_status, entry.status}}

  defp encoded_result({:ok, result}), do: {"succeeded", encode(result), nil}
  defp encoded_result({:error, error}), do: {"failed", nil, encode(inspect(error))}
  defp encoded_result(other), do: {"failed", nil, encode(inspect(other))}

  defp encode(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _reason} -> Jason.encode!(inspect(value))
    end
  end

  defp request_key(context) do
    channel = value(context, :channel)
    chat_id = value(context, :chat_id)
    session_id = value(context, :session_id)
    message_id = value(context, :message_id)
    update_id = value(context, :update_id)

    cond do
      not is_nil(channel) and not is_nil(chat_id) and not is_nil(message_id) ->
        "#{channel}:chat:#{chat_id}:message:#{message_id}"

      not is_nil(channel) and not is_nil(update_id) ->
        "#{channel}:update:#{update_id}"

      not is_nil(session_id) and not is_nil(message_id) ->
        "session:#{session_id}:message:#{message_id}"

      true ->
        nil
    end
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

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

  defp decode(nil), do: nil

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      _ -> json
    end
  end

  defp expand_path(":memory:"), do: ":memory:"
  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)
end

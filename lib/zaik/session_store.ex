defmodule Zaik.SessionStore do
  @moduledoc """
  Filesystem-backed JSONL session store.

  Session files are append-only JSONL. The first line is a `session` header;
  subsequent entries form a tree with `id` and `parentId` fields.
  """

  use GenServer

  @default_dir Path.expand("~/.zaik/sessions")

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def create(opts \\ []), do: create(__MODULE__, opts)
  def create(server, opts), do: GenServer.call(server, {:create, opts})

  def open(session_id_or_path), do: open(__MODULE__, session_id_or_path)
  def open(server, session_id_or_path), do: GenServer.call(server, {:open, session_id_or_path})

  def list(opts \\ []), do: list(__MODULE__, opts)
  def list(server, opts), do: GenServer.call(server, {:list, opts})

  def append(session_id, entry), do: append(__MODULE__, session_id, entry)
  def append(server, session_id, entry), do: GenServer.call(server, {:append, session_id, entry})

  def get_entry(session_id, entry_id), do: get_entry(__MODULE__, session_id, entry_id)

  def get_entry(server, session_id, entry_id),
    do: GenServer.call(server, {:get_entry, session_id, entry_id})

  def get_branch(session_id), do: get_branch(__MODULE__, session_id, :current)
  def get_branch(server, session_id), do: get_branch(server, session_id, :current)

  def get_branch(server, session_id, leaf_id),
    do: GenServer.call(server, {:get_branch, session_id, leaf_id})

  def branch(session_id, entry_id), do: branch(__MODULE__, session_id, entry_id)

  def branch(server, session_id, entry_id),
    do: GenServer.call(server, {:branch, session_id, entry_id})

  @impl true
  def init(opts) do
    base_dir =
      Keyword.get(opts, :base_dir, Application.get_env(:zaik, :session_dir, @default_dir))

    File.mkdir_p!(base_dir)
    {:ok, %{base_dir: base_dir, sessions: %{}}}
  end

  @impl true
  def handle_call({:create, opts}, _from, state) do
    session = new_session(state.base_dir, opts)
    File.mkdir_p!(Path.dirname(session.path))

    header = %{
      "type" => "session",
      "version" => 1,
      "id" => session.id,
      "timestamp" => DateTime.to_iso8601(session.created_at),
      "scope" => to_string(session.scope),
      "cwd" => session.cwd,
      "metadata" => session.metadata
    }

    :ok = File.write(session.path, Jason.encode!(header) <> "\n")
    Zaik.TelemetryStore.safe_record_session(session)
    {:reply, {:ok, session}, put_session(state, session)}
  end

  def handle_call({:open, id_or_path}, _from, state) do
    path = resolve_path(state, id_or_path)

    with {:ok, session} <- load_session(path) do
      {:reply, {:ok, session}, put_session(state, session)}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:list, opts}, _from, state) do
    scope = Keyword.get(opts, :scope)

    sessions =
      state.base_dir
      |> Path.join("**/*.jsonl")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        case load_session(path) do
          {:ok, session} -> [session]
          _ -> []
        end
      end)
      |> Enum.filter(fn session ->
        is_nil(scope) or session.scope == scope or session.scope == to_string(scope)
      end)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

    {:reply, sessions, state}
  end

  def handle_call({:append, session_id, entry}, _from, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, normalized} <- normalize_entry(entry, session.current_leaf_id),
         :ok <- File.write(session.path, Jason.encode!(normalized) <> "\n", [:append]) do
      updated = %{session | current_leaf_id: normalized["id"], updated_at: DateTime.utc_now()}
      Zaik.TelemetryStore.safe_record_session_entry(updated, normalized)
      {:reply, {:ok, normalized["id"]}, put_session(state, updated)}
    else
      error -> {:reply, normalize_error(error), state}
    end
  end

  def handle_call({:get_entry, session_id, entry_id}, _from, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, entries} <- read_entries(session.path) do
      case Enum.find(entries, &(&1["id"] == entry_id)) do
        nil -> {:reply, {:error, :not_found}, state}
        entry -> {:reply, {:ok, entry}, state}
      end
    else
      error -> {:reply, normalize_error(error), state}
    end
  end

  def handle_call({:get_branch, session_id, leaf_id}, _from, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, entries} <- read_entries(session.path) do
      target = if leaf_id == :current, do: session.current_leaf_id, else: leaf_id
      {:reply, build_branch(entries, target), state}
    else
      error -> {:reply, normalize_error(error), state}
    end
  end

  def handle_call({:branch, session_id, entry_id}, _from, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, entries} <- read_entries(session.path),
         true <- Enum.any?(entries, &(&1["id"] == entry_id)) do
      updated = %{session | current_leaf_id: entry_id, updated_at: DateTime.utc_now()}
      {:reply, {:ok, updated}, put_session(state, updated)}
    else
      false -> {:reply, {:error, :not_found}, state}
      error -> {:reply, normalize_error(error), state}
    end
  end

  defp new_session(base_dir, opts) do
    now = DateTime.utc_now()
    id = Keyword.get_lazy(opts, :id, &new_id/0)
    scope = Keyword.get(opts, :scope, :system)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    dir = Path.join([base_dir, safe_segment(to_string(scope)), safe_segment(cwd)])
    path = Path.join(dir, "#{DateTime.to_unix(now, :millisecond)}_#{id}.jsonl")

    %Zaik.Session{
      id: id,
      path: path,
      scope: scope,
      cwd: cwd,
      owner: Keyword.get(opts, :owner),
      current_leaf_id: nil,
      created_at: now,
      updated_at: now,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp load_session(path) do
    with true <- File.exists?(path),
         {:ok, [header | entries]} <- read_lines(path),
         %{"type" => "session", "id" => id} = header <- header do
      created_at = parse_time(header["timestamp"])
      updated_at = latest_time(entries, created_at)

      {:ok,
       %Zaik.Session{
         id: id,
         path: path,
         scope: header["scope"] || "system",
         cwd: header["cwd"],
         current_leaf_id: latest_entry_id(entries),
         created_at: created_at,
         updated_at: updated_at,
         metadata: header["metadata"] || %{}
       }}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
      _ -> {:error, :invalid_session}
    end
  end

  defp read_entries(path) do
    with {:ok, [_header | entries]} <- read_lines(path), do: {:ok, entries}
  end

  defp read_lines(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode/1)
    |> collect_decodes()
  rescue
    File.Error -> {:error, :not_found}
  end

  defp collect_decodes(decoded) do
    Enum.reduce_while(decoded, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _}, _ -> {:halt, {:error, :invalid_jsonl}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp normalize_entry(entry, current_leaf_id) when is_map(entry) do
    now = DateTime.utc_now()

    normalized =
      entry
      |> stringify_keys()
      |> Map.put_new("id", short_id())
      |> Map.put_new("parentId", current_leaf_id)
      |> Map.put_new("timestamp", DateTime.to_iso8601(now))

    if Map.has_key?(normalized, "type"),
      do: {:ok, normalized},
      else: {:error, :missing_entry_type}
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_value(%_{} = struct), do: struct |> Map.from_struct() |> stringify_keys()
  defp stringify_value(map) when is_map(map), do: stringify_keys(map)
  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(value), do: value

  defp build_branch(_entries, nil), do: {:ok, []}

  defp build_branch(entries, leaf_id) do
    by_id = Map.new(entries, &{&1["id"], &1})

    if Map.has_key?(by_id, leaf_id) do
      branch = walk_branch(by_id, leaf_id, [])
      {:ok, branch}
    else
      {:error, :not_found}
    end
  end

  defp walk_branch(_by_id, nil, acc), do: acc

  defp walk_branch(by_id, id, acc) do
    entry = Map.fetch!(by_id, id)
    walk_branch(by_id, entry["parentId"], [entry | acc])
  end

  defp fetch_session(state, session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, session} ->
        {:ok, session}

      :error ->
        case open_by_id(state, session_id) do
          {:ok, session} -> {:ok, session}
          _ -> {:error, :not_found}
        end
    end
  end

  defp open_by_id(state, session_id) do
    state.base_dir
    |> Path.join("**/*#{session_id}*.jsonl")
    |> Path.wildcard()
    |> List.first()
    |> case do
      nil -> {:error, :not_found}
      path -> load_session(path)
    end
  end

  defp resolve_path(_state, path) when is_binary(path) do
    if File.exists?(path), do: path, else: path
  end

  defp put_session(state, session),
    do: %{state | sessions: Map.put(state.sessions, session.id, session)}

  defp latest_entry_id([]), do: nil
  defp latest_entry_id(entries), do: entries |> List.last() |> Map.get("id")

  defp latest_time([], fallback), do: fallback

  defp latest_time(entries, fallback),
    do: entries |> List.last() |> Map.get("timestamp") |> parse_time(fallback)

  defp parse_time(value, fallback \\ DateTime.utc_now())
  defp parse_time(nil, fallback), do: fallback

  defp parse_time(value, fallback) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> datetime
      _ -> fallback
    end
  end

  defp safe_segment(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "default"
      segment -> segment
    end
  end

  defp normalize_error({:error, reason}), do: {:error, reason}
  defp normalize_error(other), do: other

  defp new_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp short_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
end

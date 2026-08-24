defmodule Zaik.Alerts.RuleStore do
  @moduledoc """
  Persistent alert rule store.

  The MVP stores alert rules as JSON on disk. Rules are intentionally simple and
  local-first so they are easy to inspect, back up, and delete if needed.
  """

  use GenServer

  @default_cooldown_seconds 900

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def config do
    configured = Application.get_env(:zaik, :alerts, [])

    %{
      enabled: env_bool("ZAIK_ALERTS_ENABLED", Keyword.get(configured, :enabled, true)),
      path:
        System.get_env("ZAIK_ALERTS_PATH") ||
          Keyword.get(configured, :path, "~/.zaik/alerts/rules.json"),
      default_cooldown_seconds:
        env_integer("ZAIK_ALERT_DEFAULT_COOLDOWN_SECONDS") ||
          Keyword.get(configured, :default_cooldown_seconds, @default_cooldown_seconds)
    }
  end

  def create(attrs, server \\ __MODULE__) when is_map(attrs) do
    GenServer.call(server, {:create, attrs})
  end

  def list(status \\ :active, server \\ __MODULE__) do
    GenServer.call(server, {:list, status})
  end

  def get(id, server \\ __MODULE__) when is_binary(id) do
    GenServer.call(server, {:get, id})
  end

  def cancel(id, server \\ __MODULE__) when is_binary(id) do
    GenServer.call(server, {:cancel, id})
  end

  def record_trigger(id, triggered_at, server \\ __MODULE__) when is_binary(id) do
    GenServer.call(server, {:record_trigger, id, triggered_at})
  end

  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  @impl true
  def init(opts) do
    cfg = Map.merge(config(), Map.new(opts))
    path = expand_path(cfg.path)
    File.mkdir_p!(Path.dirname(path))

    rules = load_rules(path)
    {:ok, %{path: path, rules: rules, config: cfg}}
  end

  @impl true
  def handle_call({:create, attrs}, _from, state) do
    now = DateTime.utc_now()

    rule = %{
      "id" => Map.get(attrs, :id) || Map.get(attrs, "id") || new_id(),
      "type" =>
        atom_string(Map.get(attrs, :type) || Map.get(attrs, "type") || :presence_detected),
      "scope" => atom_string(Map.get(attrs, :scope) || Map.get(attrs, "scope") || :home),
      "status" => "active",
      "starts_at" =>
        datetime_iso(Map.get(attrs, :starts_at) || Map.get(attrs, "starts_at") || now),
      "ends_at" => datetime_iso(Map.get(attrs, :ends_at) || Map.fetch!(attrs, "ends_at")),
      "notify_channel" =>
        atom_string(
          Map.get(attrs, :notify_channel) || Map.get(attrs, "notify_channel") || :telegram
        ),
      "notify_chat_id" =>
        to_string(Map.get(attrs, :notify_chat_id) || Map.get(attrs, "notify_chat_id")),
      "cooldown_seconds" =>
        Map.get(attrs, :cooldown_seconds) || Map.get(attrs, "cooldown_seconds") ||
          state.config.default_cooldown_seconds,
      "last_triggered_at" => nil,
      "trigger_count" => 0,
      "created_by" => maybe_string(Map.get(attrs, :created_by) || Map.get(attrs, "created_by")),
      "created_at" =>
        datetime_iso(Map.get(attrs, :created_at) || Map.get(attrs, "created_at") || now),
      "metadata" => Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
    }

    state = put_rule(state, rule)
    {:reply, {:ok, rule}, state}
  rescue
    error -> {:reply, {:error, error}, state}
  end

  def handle_call({:list, status}, _from, state) do
    rules =
      state.rules
      |> Map.values()
      |> filter_status(status)
      |> Enum.sort_by(& &1["ends_at"])

    {:reply, rules, state}
  end

  def handle_call({:get, id}, _from, state) do
    case Map.fetch(state.rules, id) do
      {:ok, rule} -> {:reply, {:ok, rule}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:cancel, id}, _from, state) do
    case Map.fetch(state.rules, id) do
      {:ok, rule} ->
        rule =
          Map.merge(rule, %{
            "status" => "cancelled",
            "cancelled_at" => datetime_iso(DateTime.utc_now())
          })

        state = put_rule(state, rule)
        {:reply, {:ok, rule}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:record_trigger, id, triggered_at}, _from, state) do
    case Map.fetch(state.rules, id) do
      {:ok, rule} ->
        rule = %{
          rule
          | "last_triggered_at" => datetime_iso(triggered_at),
            "trigger_count" => (rule["trigger_count"] || 0) + 1
        }

        state = put_rule(state, rule)
        {:reply, {:ok, rule}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:reset, _from, state) do
    state = %{state | rules: %{}}
    persist!(state)
    {:reply, :ok, state}
  end

  defp put_rule(state, rule) do
    state = %{state | rules: Map.put(state.rules, rule["id"], rule)}
    persist!(state)
    state
  end

  defp filter_status(rules, :all), do: rules
  defp filter_status(rules, :active), do: Enum.filter(rules, &(&1["status"] == "active"))
  defp filter_status(rules, status), do: Enum.filter(rules, &(&1["status"] == to_string(status)))

  defp load_rules(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, rules} when is_list(rules) -> Map.new(rules, &{&1["id"], &1})
          {:ok, rules} when is_map(rules) -> rules
          _ -> %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, _reason} ->
        %{}
    end
  end

  defp persist!(%{path: path, rules: rules}) do
    rules = rules |> Map.values() |> Enum.sort_by(& &1["created_at"])
    File.write!(path, Jason.encode!(rules, pretty: true))
  end

  defp datetime_iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_iso(value) when is_binary(value), do: value

  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value), do: to_string(value)

  defp maybe_string(nil), do: nil
  defp maybe_string(value), do: to_string(value)

  defp new_id do
    "alert_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end

  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)

  defp env_bool(name, fallback) do
    case System.get_env(name) do
      nil -> fallback
      value -> value |> String.downcase() |> then(&(&1 in ["1", "true", "yes", "on"]))
    end
  end

  defp env_integer(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> nil
        end
    end
  end
end

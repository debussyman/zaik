defmodule Zaik.Home.Mirror.Fixtures do
  @moduledoc """
  Loads scenario data through the production SQLite stores.

  Mirror databases live in a per-run temporary directory. The normal store
  migrations create their schemas, and fixture rows use the same public write
  APIs as production rather than maintaining a parallel evaluation schema.
  """

  alias Zaik.Home.Mirror.Scenario

  @task_statuses ~w(queued assigned running succeeded failed cancelled timed_out)a

  def paths(temp_dir) do
    %{
      home: Path.join(temp_dir, "home.db"),
      ops: Path.join(temp_dir, "zaik.db")
    }
  end

  def load(%Scenario{} = scenario, stores) when is_map(stores) do
    with :ok <- load_home_history(scenario.home_history, Map.fetch!(stores, :history_store)),
         :ok <- load_messages(section(scenario.ops_telemetry, :messages), stores.telemetry_store),
         :ok <- load_tasks(section(scenario.ops_telemetry, :tasks), stores.telemetry_store),
         :ok <-
           load_agent_chat_runs(
             section(scenario.ops_telemetry, :agent_chat_runs),
             stores.telemetry_store
           ) do
      :ok
    end
  rescue
    error -> {:error, {:invalid_mirror_fixture, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:mirror_fixture_failure, kind, reason}}
  end

  defp load_home_history(readings, store) do
    reduce_rows(readings, fn reading, _index ->
      Zaik.Home.HistoryStore.record_device(
        store,
        value(reading, :device),
        value(reading, :payload),
        value(reading, :metadata) || %{},
        observed_at: datetime!(value(reading, :observed_at))
      )
    end)
  end

  defp load_messages(messages, store) do
    reduce_rows(messages, fn message, index ->
      created_at = datetime!(value(message, :created_at))
      session_id = value(message, :session_id) || "mirror-session"
      entry_id = value(message, :id) || "mirror-message-#{index}"

      session = %Zaik.Session{
        id: session_id,
        path: "mirror://#{session_id}",
        scope: normalize_scope(value(message, :channel)),
        cwd: "mirror",
        created_at: created_at,
        updated_at: created_at,
        metadata: %{"source" => "mirror_fixture"}
      }

      entry = %{
        "id" => entry_id,
        "parentId" => nil,
        "type" => "message",
        "role" => to_string(value(message, :role) || "user"),
        "content" => to_string(value(message, :content) || ""),
        "timestamp" => DateTime.to_iso8601(created_at),
        "metadata" => %{
          "channel" => value(message, :channel),
          "sender_id" => value(message, :sender_id),
          "chat_id" => value(message, :chat_id)
        }
      }

      Zaik.TelemetryStore.record_session_entry(store, session, entry)
    end)
  end

  defp load_tasks(tasks, store) do
    reduce_rows(tasks, fn attrs, _index ->
      submitted_at = datetime!(value(attrs, :submitted_at))

      task = %Zaik.Task{
        id: value(attrs, :id),
        type: normalize_task_type(value(attrs, :type)),
        payload: value(attrs, :payload) || %{},
        priority: value(attrs, :priority) || 50,
        status: normalize_status(value(attrs, :status)),
        session_id: value(attrs, :session_id),
        result: value(attrs, :result),
        error: value(attrs, :error),
        submitted_at: submitted_at,
        started_at: optional_datetime(value(attrs, :started_at)),
        completed_at: optional_datetime(value(attrs, :completed_at)),
        timeout_ms: value(attrs, :timeout_ms) || 60_000,
        max_retries: value(attrs, :max_retries) || 0,
        attempts: value(attrs, :attempts) || 0,
        metadata: value(attrs, :metadata) || %{}
      }

      Zaik.TelemetryStore.record_task(store, task, :mirror_fixture, %{"source" => "mirror"})
    end)
  end

  defp load_agent_chat_runs(runs, store) do
    reduce_rows(runs, fn attrs, _index ->
      attrs =
        if is_nil(value(attrs, :metadata)) do
          Map.put(attrs, :metadata, %{"source" => "mirror_fixture"})
        else
          attrs
        end

      Zaik.TelemetryStore.record_agent_chat_run(store, attrs)
    end)
  end

  defp reduce_rows(rows, fun) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {row, index}, :ok ->
      case fun.(row, index) do
        :ok -> {:cont, :ok}
        other -> {:halt, {:error, {:fixture_write_failed, index, other}}}
      end
    end)
  end

  defp section(telemetry, key),
    do: Map.get(telemetry, key, Map.get(telemetry, to_string(key), []))

  defp normalize_status(status) when status in @task_statuses, do: status

  defp normalize_status(status) when is_binary(status) do
    Enum.find(@task_statuses, :failed, &(Atom.to_string(&1) == status))
  end

  defp normalize_status(_status), do: :failed

  defp normalize_task_type(type) when is_atom(type), do: type
  defp normalize_task_type("llm_prompt"), do: :llm_prompt
  defp normalize_task_type("echo"), do: :echo
  defp normalize_task_type(_type), do: :mirror_fixture

  defp normalize_scope(scope) when is_atom(scope), do: scope
  defp normalize_scope("telegram"), do: :telegram
  defp normalize_scope("signal"), do: :signal
  defp normalize_scope(_scope), do: :mirror

  defp datetime!(%DateTime{} = datetime), do: datetime

  defp datetime!(value) when is_binary(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  defp optional_datetime(nil), do: nil
  defp optional_datetime(value), do: datetime!(value)

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

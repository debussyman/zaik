defmodule Zaik.TelemetryWriteMonitor do
  @moduledoc """
  Observable fail-safe for writes that are required to leave a durable trace.

  A failed trace cannot be written to the database that just failed, so this
  process keeps a bounded in-memory diagnostic window, exposes unresolved
  categories through health APIs, and emits an error log immediately. A later
  successful write for the same category resolves its active failure.
  """

  use GenServer
  require Logger

  @max_events 100

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put_new(server_opts, :name, __MODULE__))
  end

  def report(category, result, metadata \\ %{}, server \\ __MODULE__)
      when is_atom(category) and is_map(metadata) do
    if process_available?(server) do
      GenServer.call(server, {:report, category, result, metadata})
    else
      log_failure(category, {:monitor_unavailable, result}, metadata)
      {:error, :telemetry_write_monitor_unavailable}
    end
  catch
    :exit, reason ->
      log_failure(category, {:monitor_exit, reason, result}, metadata)
      {:error, :telemetry_write_monitor_unavailable}
  end

  def status(server \\ __MODULE__) do
    if process_available?(server),
      do: GenServer.call(server, :status),
      else: %{status: :unavailable, unresolved: [], failure_count: 0, recent: []}
  catch
    :exit, _reason -> %{status: :unavailable, unresolved: [], failure_count: 0, recent: []}
  end

  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  @impl true
  def init(opts) do
    {:ok,
     %{
       clock: Keyword.get(opts, :clock),
       max_events: Keyword.get(opts, :max_events, @max_events),
       categories: %{},
       events: [],
       failure_count: 0
     }}
  end

  @impl true
  def handle_call({:report, category, result, metadata}, _from, state) do
    now = Zaik.Time.now(state.clock) |> DateTime.to_iso8601()

    if success?(result) do
      event = %{category: category, status: :succeeded, occurred_at: now, metadata: metadata}

      categories =
        Map.update(state.categories, category, success_category(now), fn existing ->
          existing
          |> Map.put(:status, :ok)
          |> Map.put(:last_success_at, now)
        end)

      {:reply, :ok, append_event(%{state | categories: categories}, event)}
    else
      reason = normalize_reason(result)

      event = %{
        category: category,
        status: :failed,
        reason: reason,
        occurred_at: now,
        metadata: metadata
      }

      category_status = %{
        status: :failed,
        failures: Map.get(state.categories[category] || %{}, :failures, 0) + 1,
        last_failure_at: now,
        last_failure: reason,
        last_success_at: Map.get(state.categories[category] || %{}, :last_success_at)
      }

      log_failure(category, reason, metadata)

      state = %{
        state
        | categories: Map.put(state.categories, category, category_status),
          failure_count: state.failure_count + 1
      }

      {:reply, {:error, reason}, append_event(state, event)}
    end
  end

  def handle_call(:status, _from, state) do
    unresolved =
      state.categories
      |> Enum.filter(fn {_category, value} -> value.status == :failed end)
      |> Enum.map(fn {category, value} -> Map.put(value, :category, category) end)
      |> Enum.sort_by(& &1.category)

    {:reply,
     %{
       status: if(unresolved == [], do: :ok, else: :degraded),
       unresolved: unresolved,
       failure_count: state.failure_count,
       recent: Enum.reverse(state.events)
     }, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | categories: %{}, events: [], failure_count: 0}}
  end

  defp success?(:ok), do: true
  defp success?({:ok, _value}), do: true
  defp success?(_result), do: false

  defp normalize_reason({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason({:error, reason}), do: bounded_inspect(reason)
  defp normalize_reason(:ignored), do: "telemetry_write_ignored"
  defp normalize_reason(other), do: bounded_inspect(other)

  defp bounded_inspect(value),
    do: value |> inspect(limit: 10, printable_limit: 300) |> String.slice(0, 500)

  defp success_category(now) do
    %{status: :ok, failures: 0, last_failure_at: nil, last_failure: nil, last_success_at: now}
  end

  defp append_event(state, event) do
    events = [event | state.events] |> Enum.take(max(1, state.max_events))
    %{state | events: events}
  end

  defp log_failure(category, reason, metadata) do
    Logger.error(
      "Required telemetry write failed category=#{category} reason=#{inspect(reason)} metadata=#{inspect(metadata)}"
    )
  end

  defp process_available?(server) when is_pid(server), do: Process.alive?(server)
  defp process_available?(server) when is_atom(server), do: not is_nil(Process.whereis(server))
  defp process_available?(_server), do: false
end

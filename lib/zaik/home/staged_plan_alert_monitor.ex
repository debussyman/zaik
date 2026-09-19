defmodule Zaik.Home.StagedPlanAlertMonitor do
  @moduledoc """
  Opt-in supervised delivery loop for staged-plan watchdog alerts.

  The monitor only invokes the read-only watchdog and explicit alert-delivery
  boundary. It has no plan scheduling, cancellation, retry, or executor API.
  """

  use GenServer

  @default_interval_seconds 60
  @default_cooldown_seconds 15 * 60
  @default_task_timeout_ms 10_000

  def config do
    configured = Application.get_env(:zaik, :home_staged_plan_alerts, [])

    %{
      enabled:
        env_bool(
          "ZAIK_HOME_STAGED_ALERTS_ENABLED",
          Keyword.get(configured, :enabled, false)
        ),
      chat_id:
        System.get_env("ZAIK_HOME_STAGED_ALERT_CHAT_ID") ||
          Keyword.get(configured, :chat_id),
      interval_seconds:
        env_integer("ZAIK_HOME_STAGED_ALERT_INTERVAL_SECONDS") ||
          Keyword.get(configured, :interval_seconds, @default_interval_seconds),
      cooldown_seconds:
        env_integer("ZAIK_HOME_STAGED_ALERT_COOLDOWN_SECONDS") ||
          Keyword.get(configured, :cooldown_seconds, @default_cooldown_seconds),
      task_timeout_ms:
        env_integer("ZAIK_HOME_STAGED_ALERT_TASK_TIMEOUT_MS") ||
          Keyword.get(configured, :task_timeout_ms, @default_task_timeout_ms)
    }
  end

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def run_now(server \\ __MODULE__), do: GenServer.call(server, :run_now)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  def barrier(server \\ __MODULE__, timeout \\ 5_000),
    do: GenServer.call(server, :barrier, timeout)

  @impl true
  def init(opts) do
    cfg = Map.merge(config(), Map.new(opts))

    with :ok <- validate_config(cfg),
         true <- process_available?(cfg.task_supervisor) do
      state = %{
        config: cfg,
        running: nil,
        timer: nil,
        runs: 0,
        failures: 0,
        timeouts: 0,
        last_result: nil,
        last_run_at: nil,
        barrier_waiters: []
      }

      {:ok, start_run(state)}
    else
      false -> {:stop, :staged_plan_alert_task_supervisor_unavailable}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:run_now, _from, %{running: nil} = state) do
    {:reply, :ok, start_run(state)}
  end

  def handle_call(:run_now, _from, state),
    do: {:reply, {:error, :alert_evaluation_running}, state}

  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  def handle_call(:barrier, _from, %{running: nil} = state), do: {:reply, :ok, state}

  def handle_call(:barrier, from, state) do
    {:noreply, %{state | barrier_waiters: [from | state.barrier_waiters]}}
  end

  @impl true
  def handle_info(:tick, %{running: nil} = state), do: {:noreply, start_run(state)}
  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({reference, result}, %{running: %{reference: reference}} = state) do
    Process.demonitor(reference, [:flush])
    state = finish_run(state, result)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, reason},
        %{running: %{reference: reference}} = state
      ) do
    state = finish_run(state, {:error, {:alert_task_exit, reason}})
    {:noreply, state}
  end

  def handle_info(
        {:run_timeout, reference},
        %{running: %{reference: reference, task: task}} = state
      ) do
    _ = Task.Supervisor.terminate_child(state.config.task_supervisor, task.pid)
    state = %{state | timeouts: state.timeouts + 1}
    state = finish_run(state, {:error, :staged_plan_alert_timeout})
    {:noreply, state}
  end

  def handle_info({:run_timeout, _stale_reference}, state), do: {:noreply, state}
  def handle_info({:DOWN, _reference, :process, _pid, _reason}, state), do: {:noreply, state}

  defp start_run(state) do
    task =
      Task.Supervisor.async_nolink(state.config.task_supervisor, fn ->
        Zaik.Home.StagedPlanAlerts.deliver(
          state.config.context,
          chat_id: state.config.chat_id,
          notifier: state.config.notifier,
          cooldown_seconds: state.config.cooldown_seconds,
          watchdog_opts: state.config.watchdog_opts
        )
      end)

    Process.send_after(self(), {:run_timeout, task.ref}, state.config.task_timeout_ms)

    %{
      state
      | running: %{reference: task.ref, task: task},
        last_run_at: Zaik.Time.now(state.config.clock) |> DateTime.to_iso8601()
    }
  end

  defp finish_run(state, result) do
    failures = if successful_result?(result), do: state.failures, else: state.failures + 1

    state = %{
      state
      | running: nil,
        runs: state.runs + 1,
        failures: failures,
        last_result: result
    }

    Enum.each(state.barrier_waiters, &GenServer.reply(&1, :ok))
    state |> Map.put(:barrier_waiters, []) |> schedule(state.config.interval_seconds)
  end

  defp successful_result?({:ok, %{errors: 0}}), do: true
  defp successful_result?(_result), do: false

  defp schedule(state, seconds) do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)
    timer = Process.send_after(self(), :tick, seconds * 1_000)
    %{state | timer: timer}
  end

  defp public_status(state) do
    %{
      running: not is_nil(state.running),
      runs: state.runs,
      failures: state.failures,
      timeouts: state.timeouts,
      last_result: state.last_result,
      last_run_at: state.last_run_at,
      interval_seconds: state.config.interval_seconds
    }
  end

  defp validate_config(cfg) do
    cond do
      not is_binary(cfg.chat_id) or String.trim(cfg.chat_id) == "" ->
        {:error, :staged_plan_alert_chat_id_required}

      not is_integer(cfg.interval_seconds) or cfg.interval_seconds < 1 ->
        {:error, :invalid_staged_plan_alert_interval}

      not is_integer(cfg.cooldown_seconds) or cfg.cooldown_seconds < 1 ->
        {:error, :invalid_staged_plan_alert_cooldown}

      not is_integer(cfg.task_timeout_ms) or cfg.task_timeout_ms < 1 ->
        {:error, :invalid_staged_plan_alert_task_timeout}

      not is_map(cfg.context) ->
        {:error, :invalid_staged_plan_alert_context}

      not (is_atom(cfg.notifier) or is_function(cfg.notifier, 2)) ->
        {:error, :invalid_staged_plan_notifier}

      true ->
        :ok
    end
  end

  defp process_available?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp process_available?(name) when is_atom(name), do: not is_nil(Process.whereis(name))
  defp process_available?(_value), do: false

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
          {integer, ""} -> integer
          _ -> nil
        end
    end
  end
end

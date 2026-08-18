defmodule Zaik.Scheduler do
  @moduledoc """
  Lightweight supervised scheduler for recurring Zaik jobs.

  This is deliberately small and OTP-native: jobs are configured in application env,
  timers are driven by `Process.send_after/3`, and job execution is isolated so a
  failing job does not crash the scheduler. The scheduler is intended for local
  maintenance loops such as eval sweeps, summaries, and proposal generation.
  """

  use GenServer
  require Logger

  @type schedule :: {:daily, binary()} | {:interval_ms, pos_integer()}
  @type job :: %{
          name: atom(),
          module: module(),
          schedule: schedule(),
          opts: keyword(),
          enabled: boolean()
        }

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def config do
    configured = Application.get_env(:zaik, :scheduler, [])

    %{
      enabled: env_bool("ZAIK_SCHEDULER_ENABLED", Keyword.get(configured, :enabled, true)),
      jobs: Keyword.get(configured, :jobs, [])
    }
  end

  @doc "Return the scheduler state summary."
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @doc "Return configured jobs."
  def jobs(server \\ __MODULE__), do: GenServer.call(server, :jobs)

  @doc "Run a job immediately, regardless of its recurring enabled flag."
  def run_now(name, server \\ __MODULE__) when is_atom(name),
    do: GenServer.call(server, {:run_now, name})

  @doc false
  def next_delay_ms({:interval_ms, interval_ms}, _now)
      when is_integer(interval_ms) and interval_ms > 0,
      do: interval_ms

  def next_delay_ms({:daily, time_text}, %DateTime{} = now) when is_binary(time_text) do
    with {:ok, time} <- Time.from_iso8601(time_text),
         {:ok, today_target} <- DateTime.new(DateTime.to_date(now), time, "Etc/UTC") do
      target =
        if DateTime.compare(today_target, now) == :gt,
          do: today_target,
          else: DateTime.add(today_target, 1, :day)

      max(DateTime.diff(target, now, :millisecond), 1)
    else
      _ -> {:error, :invalid_schedule}
    end
  end

  def next_delay_ms(_schedule, _now), do: {:error, :invalid_schedule}

  @impl true
  def init(opts) do
    jobs =
      opts
      |> Keyword.get(:jobs, config().jobs)
      |> Enum.map(&normalize_job!/1)
      |> Map.new(&{&1.name, &1})

    state = %{
      jobs: jobs,
      timers: %{},
      last_runs: %{},
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0)
    }

    {:ok, schedule_enabled_jobs(state)}
  end

  @impl true
  def handle_call(:state, _from, state) do
    summary = %{
      jobs:
        state.jobs |> Map.values() |> Enum.map(&Map.drop(&1, [:opts])) |> Enum.sort_by(& &1.name),
      timers: Map.keys(state.timers) |> Enum.sort(),
      last_runs: state.last_runs
    }

    {:reply, summary, state}
  end

  def handle_call(:jobs, _from, state), do: {:reply, Map.values(state.jobs), state}

  def handle_call({:run_now, name}, _from, state) do
    case Map.fetch(state.jobs, name) do
      {:ok, job} ->
        run_job_async(job)
        {:reply, :ok, mark_last_run(state, name)}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:run_job, name}, state) do
    state = cancel_timer(state, name)

    state =
      case Map.fetch(state.jobs, name) do
        {:ok, job} ->
          if job.enabled do
            run_job_async(job)
            state |> mark_last_run(name) |> schedule_job(job)
          else
            state
          end

        :error ->
          state
      end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.timers, fn {_name, ref} -> Process.cancel_timer(ref) end)
    :ok
  end

  defp schedule_enabled_jobs(state) do
    state.jobs
    |> Map.values()
    |> Enum.filter(& &1.enabled)
    |> Enum.reduce(state, &schedule_job(&2, &1))
  end

  defp schedule_job(state, job) do
    now = state.now_fun.()

    case next_delay_ms(job.schedule, now) do
      delay_ms when is_integer(delay_ms) and delay_ms > 0 ->
        ref = Process.send_after(self(), {:run_job, job.name}, delay_ms)
        %{state | timers: Map.put(state.timers, job.name, ref)}

      {:error, reason} ->
        Logger.warning("Scheduler did not schedule #{inspect(job.name)}: #{inspect(reason)}")
        state
    end
  end

  defp cancel_timer(state, name) do
    case Map.pop(state.timers, name) do
      {nil, timers} ->
        %{state | timers: timers}

      {ref, timers} ->
        Process.cancel_timer(ref)
        %{state | timers: timers}
    end
  end

  defp run_job_async(job) do
    Task.start(fn ->
      Logger.info("Scheduler running #{inspect(job.name)}")

      result =
        try do
          cond do
            function_exported?(job.module, :run, 1) -> apply(job.module, :run, [job.opts])
            function_exported?(job.module, :run, 0) -> apply(job.module, :run, [])
            true -> {:error, :missing_run_callback}
          end
        rescue
          error -> {:error, {error.__struct__, Exception.message(error)}}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      case result do
        :ok ->
          Logger.info("Scheduler completed #{inspect(job.name)}")

        {:ok, _value} ->
          Logger.info("Scheduler completed #{inspect(job.name)}")

        {:error, reason} ->
          Logger.warning("Scheduler job #{inspect(job.name)} failed: #{inspect(reason)}")

        other ->
          Logger.info("Scheduler completed #{inspect(job.name)} with #{inspect(other)}")
      end
    end)

    :ok
  end

  defp mark_last_run(state, name) do
    %{state | last_runs: Map.put(state.last_runs, name, state.now_fun.())}
  end

  defp normalize_job!(job) when is_list(job), do: job |> Map.new() |> normalize_job!()

  defp normalize_job!(job) when is_map(job) do
    %{
      name: Map.fetch!(job, :name),
      module: Map.fetch!(job, :module),
      schedule: Map.fetch!(job, :schedule),
      opts: Map.get(job, :opts, []),
      enabled: Map.get(job, :enabled, true)
    }
  end

  defp env_bool(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> value |> String.downcase() |> then(&(&1 in ["1", "true", "yes", "on"]))
    end
  end
end

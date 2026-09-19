defmodule Zaik.Home.StagedPlanScheduler do
  @moduledoc """
  Supervised virtual-time wakeups for mirror-only staged plans.

  Waiting and interrupted running plans are reconstructed from durable storage.
  This process never executes a stage itself; it invokes the mirror-only staged
  coordinator when a persisted evaluation time becomes due.
  """

  use GenServer

  def start_link(opts) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def submit(plan_id, server) when is_binary(plan_id),
    do: GenServer.call(server, {:submit, plan_id})

  def status(server), do: GenServer.call(server, :status)
  def sync_observations(server), do: GenServer.call(server, :sync_observations)
  def barrier(server, timeout \\ 5_000), do: GenServer.call(server, :barrier, timeout)

  @impl true
  def init(opts) do
    context = Keyword.fetch!(opts, :context)

    with :ok <- mirror_context(context),
         :ok <- Zaik.Home.Mirror.Store.set_observer(context.mirror_store, self()) do
      send(self(), :recover)

      {:ok,
       %{
         context: context,
         clock: Map.fetch!(context, :clock),
         task_supervisor: Map.fetch!(context, :task_supervisor),
         scheduled: %{},
         running: %{},
         last_results: %{},
         attempts: %{},
         observation_wakeups: %{},
         barrier_waiters: []
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:submit, plan_id}, _from, state) do
    case Zaik.Home.StagedPlanStore.lookup(
           plan_id,
           [clock: state.clock],
           state.context.staged_plan_store
         ) do
      {:ok, %{status: status} = plan} when status in ["prepared", "waiting", "running"] ->
        next = schedule_plan(state, plan)
        record_event(next, plan_id, "scheduled", schedule_status(next, plan_id))
        {:reply, {:ok, schedule_status(next, plan_id)}, next}

      {:ok, plan} ->
        {:reply, {:error, {:staged_plan_not_schedulable, plan.status}}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}
  def handle_call(:sync_observations, _from, state), do: {:reply, :ok, state}

  def handle_call(:barrier, from, state) do
    if map_size(state.running) == 0 do
      {:reply, :ok, state}
    else
      {:noreply, %{state | barrier_waiters: [from | state.barrier_waiters]}}
    end
  end

  @impl true
  def handle_info(:recover, state) do
    next =
      Zaik.Home.StagedPlanStore.active([clock: state.clock], state.context.staged_plan_store)
      |> Enum.filter(&(&1.status in ["waiting", "running"]))
      |> Enum.reduce(state, fn plan, current ->
        event_type =
          if plan.status == "waiting", do: "recovered_waiting", else: "recovered_running"

        record_event(current, plan.id, event_type, %{current_stage: plan.current_stage})
        schedule_plan(current, plan)
      end)

    {:noreply, next}
  end

  def handle_info({:canonical_observation, observation}, state) do
    next =
      state.scheduled
      |> Map.keys()
      |> Enum.reduce(state, fn plan_id, current ->
        maybe_wake_for_observation(current, plan_id, observation)
      end)

    {:noreply, next}
  end

  def handle_info({:wake, plan_id, generation}, state) do
    case Map.get(state.scheduled, plan_id) do
      %{generation: ^generation} ->
        state = %{state | scheduled: Map.delete(state.scheduled, plan_id)}
        {:noreply, start_run(state, plan_id)}

      _stale_or_cancelled ->
        {:noreply, state}
    end
  end

  def handle_info({reference, result}, state) when is_reference(reference) do
    case Map.pop(state.running, reference) do
      {nil, _running} ->
        {:noreply, state}

      {plan_id, running} ->
        Process.demonitor(reference, [:flush])

        state = %{
          state
          | running: running,
            last_results: Map.put(state.last_results, plan_id, result)
        }

        record_event(state, plan_id, result_event_type(result), %{
          result: diagnostic_result(result)
        })

        state = maybe_reschedule(state, plan_id, result)
        {:noreply, release_barriers(state)}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state) do
    case Map.pop(state.running, reference) do
      {nil, _running} ->
        {:noreply, state}

      {plan_id, running} ->
        result = {:error, {:staged_plan_scheduler_task_exit, reason}}

        state = %{
          state
          | running: running,
            last_results: Map.put(state.last_results, plan_id, result)
        }

        record_event(state, plan_id, "task_exit", %{reason: inspect(reason)})
        {:noreply, release_barriers(state)}
    end
  end

  defp start_run(state, plan_id) do
    record_event(state, plan_id, "evaluation_started", %{
      attempt: Map.get(state.attempts, plan_id, 0) + 1
    })

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Zaik.Home.StagedPlanCoordinator.run(plan_id, state.context)
      end)

    %{
      state
      | running: Map.put(state.running, task.ref, plan_id),
        attempts: Map.update(state.attempts, plan_id, 1, &(&1 + 1))
    }
  end

  defp maybe_reschedule(state, _plan_id, {:ok, %{status: "waiting"} = plan}),
    do: schedule_plan(state, plan)

  defp maybe_reschedule(
         state,
         plan_id,
         {:error, {:staged_plan_wait_not_ready, %{next_evaluation_at: next_evaluation_at}}}
       ) do
    schedule_at(state, plan_id, next_evaluation_at)
  end

  defp maybe_reschedule(state, _plan_id, _result), do: state

  defp schedule_plan(state, %{id: plan_id, status: status})
       when status in ["prepared", "running"] do
    schedule_after(state, plan_id, 0, Zaik.Time.now(state.clock))
  end

  defp schedule_plan(state, %{id: plan_id, status: "waiting"} = plan) do
    schedule_at(state, plan_id, plan.next_evaluation_at)
  end

  defp schedule_at(state, plan_id, nil),
    do: schedule_after(state, plan_id, 0, Zaik.Time.now(state.clock))

  defp schedule_at(state, plan_id, timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, due_at, _offset} ->
        delay = max(DateTime.diff(due_at, Zaik.Time.now(state.clock), :millisecond), 0)
        schedule_after(state, plan_id, delay, due_at)

      _ ->
        %{
          state
          | last_results:
              Map.put(state.last_results, plan_id, {:error, :invalid_staged_plan_wait_schedule})
        }
    end
  end

  defp schedule_after(state, plan_id, delay_ms, due_at) do
    generation =
      case Map.get(state.scheduled, plan_id) do
        %{generation: current} -> current + 1
        nil -> 1
      end

    _timer =
      Zaik.Home.Mirror.Clock.send_after(
        clock_pid(state.clock),
        self(),
        {:wake, plan_id, generation},
        delay_ms
      )

    scheduled = %{
      generation: generation,
      due_at: DateTime.to_iso8601(due_at),
      delay_ms: delay_ms
    }

    %{state | scheduled: Map.put(state.scheduled, plan_id, scheduled)}
  end

  defp release_barriers(%{running: running, barrier_waiters: waiters} = state)
       when map_size(running) == 0 do
    Enum.each(waiters, &GenServer.reply(&1, :ok))
    %{state | barrier_waiters: []}
  end

  defp release_barriers(state), do: state

  defp schedule_status(state, plan_id) do
    %{
      plan_id: plan_id,
      scheduled: Map.get(state.scheduled, plan_id),
      running: running?(state, plan_id)
    }
  end

  defp public_status(state) do
    watchdog =
      case Zaik.Home.StagedPlanWatchdog.evaluate(state.context) do
        {:ok, diagnostics} -> diagnostics
        {:error, reason} -> %{status: "unavailable", reason: inspect(reason)}
      end

    %{
      scheduled: state.scheduled,
      running: state.running |> Map.values() |> Enum.sort(),
      attempts: state.attempts,
      observation_wakeups: state.observation_wakeups,
      last_results: state.last_results,
      watchdog: watchdog
    }
  end

  defp running?(state, plan_id), do: plan_id in Map.values(state.running)

  defp maybe_wake_for_observation(state, plan_id, observation) do
    with {:ok, %{status: "waiting"} = plan} <-
           Zaik.Home.StagedPlanStore.lookup(
             plan_id,
             [clock: state.clock],
             state.context.staged_plan_store
           ),
         true <- observation_matches?(plan, observation),
         {:ok, awakened} <-
           Zaik.Home.StagedPlanStore.wake_waiting(
             plan_id,
             observation.observed_at,
             [clock: state.clock],
             state.context.staged_plan_store
           ) do
      next =
        state
        |> Map.update!(
          :observation_wakeups,
          &Map.update(&1, plan_id, 1, fn count -> count + 1 end)
        )
        |> schedule_plan(awakened)

      record_event(next, plan_id, "observation_wakeup", %{
        observed_at: DateTime.to_iso8601(observation.observed_at),
        device: observation.device,
        wakeup_count: awakened.observation_wakeup_count
      })

      next
    else
      _ -> state
    end
  end

  defp observation_matches?(plan, observation) do
    stage = Enum.at(get_in(plan, [:plan, "stages"]) || [], plan.current_stage) || %{}

    inputs =
      if plan.waiting_kind == "verification",
        do: Map.get(stage, "actions", []),
        else: Map.get(stage, "conditions", [])

    Enum.any?(inputs, fn input ->
      same_device?(Map.get(input, "device"), observation.device) and
        relevant_payload?(input, observation.payload)
    end)
  end

  defp same_device?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(String.trim(left)) == String.downcase(String.trim(right))

  defp same_device?(_left, _right), do: false

  defp relevant_payload?(condition, payload) when is_map(payload) do
    capability = Map.get(condition, "capability")
    field = Map.get(condition, "field") || verification_field(capability)

    keys =
      case {capability, field} do
        {"temperature", value} when value in ["celsius", "fahrenheit"] ->
          [{"temperature", :temperature}]

        {"humidity", "percent"} ->
          [{"humidity", :humidity}]

        {"illuminance", "value"} ->
          [{"illuminance", :illuminance}]

        {"presence", "occupied"} ->
          [{"presence", :presence}, {"occupancy", :occupancy}]

        {"cover", "position"} ->
          [{"position", :position}]

        {"battery", "percent"} ->
          [{"battery", :battery}]

        {"linkquality", "value"} ->
          [{"linkquality", :linkquality}]

        _ ->
          []
      end

    Enum.any?(keys, fn {string_key, atom_key} ->
      Map.has_key?(payload, string_key) or Map.has_key?(payload, atom_key)
    end)
  end

  defp relevant_payload?(_condition, _payload), do: false

  defp verification_field("temperature"), do: "celsius"
  defp verification_field("humidity"), do: "percent"
  defp verification_field("illuminance"), do: "value"
  defp verification_field("presence"), do: "occupied"
  defp verification_field("cover"), do: "position"
  defp verification_field("battery"), do: "percent"
  defp verification_field("linkquality"), do: "value"
  defp verification_field(_capability), do: nil

  defp result_event_type({:ok, %{status: status}})
       when status in ["waiting", "completed", "cancelled", "failed"],
       do: status

  defp result_event_type({:error, :staged_plan_coordinator_timeout}), do: "timed_out"
  defp result_event_type({:error, {:staged_plan_failed, _plan}}), do: "failed"
  defp result_event_type({:error, {:staged_plan_wait_not_ready, _attrs}}), do: "waiting"
  defp result_event_type(_result), do: "failed"

  defp diagnostic_result({:ok, result}) when is_map(result) do
    Map.take(result, [
      :id,
      :status,
      :current_stage,
      :completed_at,
      :next_evaluation_at,
      :observation_wakeup_count
    ])
  end

  defp diagnostic_result({:error, reason}), do: %{error: inspect(reason)}
  defp diagnostic_result(result), do: %{result: inspect(result)}

  defp record_event(state, plan_id, event_type, attrs) do
    _ =
      Zaik.Home.StagedPlanStore.record_run_event(
        plan_id,
        event_type,
        attrs,
        [clock: state.clock],
        state.context.staged_plan_store
      )

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp mirror_context(context) do
    modules = context |> Map.get(:executor_opts, []) |> Keyword.get(:modules, [])

    cond do
      not is_binary(Map.get(context, :mirror_scenario_id)) ->
        {:error, :staged_plan_scheduler_not_enabled}

      modules != [Zaik.Home.Mirror.Executor] ->
        {:error, :staged_plan_scheduler_not_enabled}

      not match?({Zaik.Home.Mirror.Clock, pid} when is_pid(pid), Map.get(context, :clock)) ->
        {:error, :staged_plan_scheduler_not_enabled}

      not Enum.all?(
        [:mirror_store, :staged_plan_store, :action_ledger, :task_supervisor],
        &(is_pid(Map.get(context, &1)) and Process.alive?(Map.get(context, &1)))
      ) ->
        {:error, :staged_plan_scheduler_not_enabled}

      true ->
        :ok
    end
  end

  defp clock_pid({Zaik.Home.Mirror.Clock, pid}), do: pid
end

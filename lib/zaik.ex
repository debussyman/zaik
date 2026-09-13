defmodule Zaik do
  @moduledoc """
  Zaik is a personal AI agent runtime inspired by OpenClaw, built with Elixir's actor system.

  The system is designed to run multiple AI agents that can:
  - Process messages 
  - Handle periodic ticks
  - Store state
  - Communicate with each other
  """

  @doc """
  Start the Zaik system with all required supervisors and agents.
  """
  def start do
    Application.start(:zaik)
  end

  @doc """
  Stop the Zaik system.
  """
  def stop do
    Application.stop(:zaik)
  end

  @doc """
  Create a filesystem-backed session.
  """
  def create_session(opts \\ []) do
    Zaik.SessionStore.create(opts)
  end

  @doc """
  List filesystem-backed sessions.
  """
  def list_sessions(opts \\ []) do
    Zaik.SessionStore.list(opts)
  end

  @doc """
  Build context from a session's active branch.
  """
  def get_session_context(session_id, opts \\ []) do
    Zaik.ContextBuilder.build(session_id, opts)
  end

  @doc """
  Return a structured runtime snapshot of the harness.
  """
  def snapshot, do: Zaik.Observability.snapshot()

  @doc """
  Return top-level harness health.
  """
  def health, do: Zaik.Observability.health()

  @doc """
  Return task counts by status.
  """
  def task_summary, do: Zaik.Observability.task_summary()

  @doc """
  Return latest known home devices.
  """
  def home_devices, do: Zaik.Home.DeviceStore.list_devices()

  @doc """
  Find a home device by exact name or unique case-insensitive substring.
  """
  def home_device(query), do: Zaik.Home.DeviceStore.find_device(query)

  @doc """
  Persist an explicit area and aliases for a canonical home entity.
  """
  def configure_home_entity(device_query, area_id, aliases \\ []) do
    Zaik.Home.HistoryStore.configure_entity(device_query, area_id, aliases)
  end

  @doc """
  Build a deterministic current, historical, occupancy, and environment context
  for a room or area without executing an action.
  """
  def home_room_context(query, opts \\ []), do: Zaik.Home.RoomContext.build(query, opts)

  @doc """
  Build and validate the independently gathered evidence required by a
  versioned household goal skill without planning or execution.
  """
  def home_goal_context(skill_or_goal, opts \\ []),
    do: Zaik.Home.GoalContextBuilder.build(skill_or_goal, opts)

  @doc """
  Evaluate configured home policies in the inert shadow/advisory pipeline.
  Canary and active execution are not enabled by this API.
  """
  def evaluate_home_autonomy(query, opts \\ []),
    do: Zaik.Home.Autonomy.Engine.evaluate(query, opts)

  @doc """
  Return the current supervised home-autonomy evaluator status.
  """
  def home_autonomy_status, do: Zaik.Home.Autonomy.Engine.status()

  @doc """
  Pause event and explicit home-autonomy evaluation until resumed.
  """
  def pause_home_autonomy(reason \\ "operator pause", paused_by \\ "operator"),
    do: Zaik.Home.Autonomy.Engine.pause(reason, paused_by)

  @doc """
  Resume home-autonomy evaluation after an operator pause.
  """
  def resume_home_autonomy(resumed_by \\ "operator"),
    do: Zaik.Home.Autonomy.Engine.resume(resumed_by)

  @doc """
  Change the runtime autonomy mode. Only off, shadow, and advisory are accepted.
  """
  def set_home_autonomy_mode(mode, changed_by \\ "operator"),
    do: Zaik.Home.Autonomy.Engine.set_mode(mode, changed_by)

  @doc """
  Return recent durable home-autonomy decisions.
  """
  def home_autonomy_decisions(limit \\ 20),
    do: Zaik.Home.Autonomy.DecisionStore.recent(limit)

  @doc """
  Return current autonomous-action budget usage for an area and globally.
  """
  def home_action_budget_status(scope \\ "home", opts \\ []),
    do: Zaik.Home.Autonomy.ActionBudgetStore.usage(scope, opts)

  @doc """
  Return active durable desired-state leases selected by home arbitration.
  """
  def home_desired_states(scope \\ nil, opts \\ []),
    do: Zaik.Home.Autonomy.DesiredStateStore.active(scope, opts)

  @doc """
  Activate a typed, expiring household mode such as bedtime or privacy.
  """
  def activate_home_mode(scope, mode, attrs \\ %{}),
    do: Zaik.Home.Autonomy.ModeStore.activate(scope, mode, attrs)

  @doc """
  Return active household modes for an area.
  """
  def home_modes(scope, opts \\ []), do: Zaik.Home.Autonomy.ModeStore.active(scope, opts)

  @doc """
  Cancel a household mode while retaining its audit record.
  """
  def cancel_home_mode(id, cancelled_by \\ "operator"),
    do: Zaik.Home.Autonomy.ModeStore.cancel(id, cancelled_by)

  @doc """
  Create an expiring manual-override lease that suppresses background autonomy
  for an area (or `home`).
  """
  def create_home_manual_override(scope, attrs \\ %{}),
    do: Zaik.Home.Autonomy.ManualOverrideStore.create(scope, attrs)

  @doc """
  Return active manual overrides for an area at the current time.
  """
  def home_manual_overrides(scope, opts \\ []),
    do: Zaik.Home.Autonomy.ManualOverrideStore.active(scope, opts)

  @doc """
  Cancel an active manual override while retaining its audit record.
  """
  def cancel_home_manual_override(id, cancelled_by \\ "operator"),
    do: Zaik.Home.Autonomy.ManualOverrideStore.cancel(id, cancelled_by)

  @doc """
  Return debounced occupancy state and its latest transition for an area.
  """
  def home_occupancy(area), do: Zaik.Home.OccupancyTracker.status(area)

  @doc """
  Return latest known devices that expose a presence field.
  """
  def presence_devices, do: Zaik.Home.DeviceStore.presence_devices()

  @doc """
  Return MQTT client connection status.
  """
  def mqtt_status, do: Zaik.MQTT.Client.status()

  @doc """
  Return runtime verification status for an action correlation ID, falling
  back to its persistent action-ledger entry after verifier retention expires.
  """
  def home_action_status(action_id) do
    case Zaik.Home.ActionVerifier.status(action_id) do
      {:ok, status} -> {:ok, %{source: :verifier, status: status}}
      {:error, :not_found} -> persistent_home_action_status(action_id)
      error -> error
    end
  catch
    :exit, _reason -> persistent_home_action_status(action_id)
  end

  @doc """
  Cancel a pending ambiguous action so a conflicting replacement may be issued.

  This never marks physical convergence and is intentionally operator-only.
  """
  def resolve_home_action(action_id, resolution, reason \\ "operator_cancelled")

  def resolve_home_action(action_id, :cancel, reason) do
    Zaik.Home.ActionVerifier.cancel(action_id, reason)
  end

  def resolve_home_action(_action_id, resolution, _reason),
    do: {:error, {:unsupported_resolution, resolution}}

  @doc """
  Reset the bounded retry count for an existing action and retain an audit row.
  """
  def reset_home_action_retry_budget(action_id, reset_by \\ nil) do
    Zaik.Home.ActionLedger.reset_retry_budget(action_id, reset_by)
  end

  @doc """
  Evaluate deterministic retry eligibility without executing an action.
  """
  def home_action_retry_eligibility(action_id, context \\ %{}) do
    with {:ok, entry} <- Zaik.Home.ActionLedger.lookup(action_id) do
      Zaik.Home.ActionRetryPolicy.evaluate(entry, context)
    end
  end

  @doc """
  Retry an eligible low-risk home action through the supervised tool boundary.
  """
  def retry_home_action(action_id, context \\ %{}) do
    context =
      context
      |> Map.put_new(:channel, :local)
      |> Map.put_new(:chat_id, "home-action-retry")
      |> Map.put_new(:message_id, Zaik.Home.ActionVerifier.new_id("retry_request"))

    Zaik.Tools.Executor.run("retry_home_action", %{"action_id" => action_id}, context)
  end

  @doc """
  Return generic named home-device presets.
  """
  def device_presets(device_name \\ nil, opts \\ []),
    do: Zaik.Home.DevicePresetStore.list(device_name, opts)

  @doc """
  Return latest known blinds/window coverings.
  """
  def blinds(query \\ nil, opts \\ []), do: Zaik.Home.Blinds.list(query, opts)

  @doc """
  Control a known blind/window covering through a validated home adapter.
  """
  def control_blind(query, target, opts \\ []), do: Zaik.Home.Blinds.control(query, target, opts)

  @doc """
  Capture the current position of a blind as a named preset.
  """
  def capture_blind_preset(query, preset_name, context \\ %{}, opts \\ []),
    do: Zaik.Home.Blinds.capture(query, preset_name, context, opts)

  @doc """
  Analyze recent telemetry trend for a home device.
  """
  def home_trend(query, opts \\ []), do: Zaik.Home.Trends.analyze(query, opts)

  @doc """
  Return recent historical readings for a home device.
  """
  def home_readings(query, opts \\ []), do: Zaik.Home.HistoryStore.recent_readings(query, opts)

  @doc """
  Run a safe read-only analytics SQL query against Zaik views.
  """
  def sql_query(sql, opts \\ []), do: Zaik.Analytics.SQLTool.run(sql, opts)

  @doc """
  Ask the bounded read-only conversational agent.
  """
  def agent_chat(text, context \\ %{}, opts \\ []),
    do: Zaik.AgentChat.respond(text, context, opts)

  @doc """
  Return scheduled job state.
  """
  def scheduler_state, do: Zaik.Scheduler.state()

  @doc """
  Run a scheduled job immediately.
  """
  def run_scheduled_job(name), do: Zaik.Scheduler.run_now(name)

  @doc """
  List active alert rules by default.
  """
  def alerts(status \\ :active), do: Zaik.Alerts.list(status)

  @doc """
  Fetch one alert rule.
  """
  def alert(id), do: Zaik.Alerts.get(id)

  @doc """
  Cancel an alert rule.
  """
  def cancel_alert(id), do: Zaik.Alerts.cancel(id)

  @doc """
  List pending proposals that require human confirmation.
  """
  def proposals(status \\ :pending), do: Zaik.Proposals.list(status)

  @doc """
  Fetch a proposal by ID.
  """
  def proposal(id), do: Zaik.Proposals.get(id)

  @doc """
  Approve a pending proposal without executing it.
  """
  def approve_proposal(id, decided_by \\ nil), do: Zaik.Proposals.approve(id, decided_by)

  @doc """
  Reject a pending proposal.
  """
  def reject_proposal(id, decided_by \\ nil), do: Zaik.Proposals.reject(id, decided_by)

  @doc """
  Run the task watchdog reconciliation immediately.
  """
  def watchdog_scan, do: Zaik.TaskWatchdog.scan_now()

  @doc """
  Return the task watchdog state.
  """
  def watchdog_state, do: Zaik.TaskWatchdog.state()

  @doc """
  Submit a task to the harness.
  """
  def submit_task(type, payload, opts \\ []) do
    task = Zaik.Task.new(type, payload, opts)

    # Store the task in the task store first
    case Zaik.TaskStore.insert(task) do
      {:ok, _} ->
        # Add to session memory if session-scoped
        if task.session_id do
          # Append task to session's memory
          Zaik.MemoryStore.append_task(task, task.session_id)
        end

        # Enqueue and dispatch
        Zaik.TaskQueue.enqueue(task)
        Zaik.Dispatcher.dispatch_now()
        {:ok, task.id}

      error ->
        error
    end
  end

  @doc """
  Await completion of a task.
  """
  def await_task(task_id, timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_task(task_id, deadline)
  end

  @doc """
  Cancel a queued task.
  """
  def cancel_task(task_id) do
    case Zaik.TaskStore.get(task_id) do
      {:ok, %Zaik.Task{status: :queued} = task} ->
        Zaik.TaskQueue.remove(task_id)
        Zaik.TaskStore.update(Zaik.Task.mark_cancelled(task))
        {:ok, :cancelled}

      {:ok, %Zaik.Task{status: :running}} ->
        Zaik.Dispatcher.cancel_task(task_id)

      {:ok, %Zaik.Task{status: status}}
      when status in [:succeeded, :failed, :cancelled, :timed_out] ->
        {:error, {:already_terminal, status}}

      {:ok, %Zaik.Task{status: status}} ->
        {:error, {:cannot_cancel, status}}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Fetch a task by ID.
  """
  def get_task(task_id) do
    Zaik.TaskStore.get(task_id)
  end

  @doc """
  List tasks from the in-memory task store.
  """
  def list_tasks(opts \\ []) do
    Zaik.TaskStore.list(Zaik.TaskStore, opts)
  end

  @doc """
  Get the current task queue size.
  """
  def queue_size do
    Zaik.TaskQueue.size()
  end

  @doc """
  Get a greeting from the hello world agent.
  """
  def hello do
    Zaik.Agent.HelloWorld.hello()
  end

  @doc """
  Send a message to the hello world agent.
  """
  def send_message(message) do
    Zaik.Agent.HelloWorld.send_message(message)
  end

  defp persistent_home_action_status(action_id) do
    case Zaik.Home.ActionLedger.lookup(action_id) do
      {:ok, entry} -> {:ok, %{source: :ledger, status: entry}}
      error -> error
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp do_await_task(task_id, deadline) do
    case Zaik.TaskStore.get(task_id) do
      {:ok, %Zaik.Task{status: :succeeded, result: result}} ->
        {:ok, result}

      {:ok, %Zaik.Task{status: :failed, error: error}} ->
        {:error, {:task_failed, error}}

      {:ok, %Zaik.Task{status: :cancelled}} ->
        {:error, :cancelled}

      {:ok, %Zaik.Task{status: :timed_out}} ->
        {:error, :task_timed_out}

      {:ok, _task} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(20)
          do_await_task(task_id, deadline)
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end

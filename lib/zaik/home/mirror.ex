defmodule Zaik.Home.Mirror do
  @moduledoc """
  Isolated deterministic virtual home for planning and safety evaluations.

  A mirror uses production world, capability, plan, verification, ledger, and
  retry modules. Only its executor and device transitions are virtual, and all
  stores are isolated from production MQTT and SQLite files.
  """

  alias Zaik.Home.Mirror.Scenario

  defstruct [
    :scenario,
    :supervisor,
    :temp_dir,
    :clock,
    :device_store,
    :occupancy_tracker,
    :history_store,
    :telemetry_store,
    :home_db_path,
    :ops_db_path,
    :preset_store,
    :manual_override_store,
    :desired_state_store,
    :action_budget_store,
    :action_verifier,
    :action_ledger,
    :task_supervisor,
    :store
  ]

  @type t :: %__MODULE__{}

  def start(%Scenario{} = scenario) do
    with {:ok, temp_dir} <- create_temp_dir(scenario) do
      case DynamicSupervisor.start_link(strategy: :one_for_one) do
        {:ok, supervisor} ->
          case start_runtime(supervisor, scenario, temp_dir) do
            {:ok, mirror} ->
              {:ok, mirror}

            {:error, reason} ->
              safe_stop(supervisor)
              cleanup_temp_dir(temp_dir)
              {:error, reason}
          end

        {:error, reason} ->
          cleanup_temp_dir(temp_dir)
          {:error, reason}
      end
    end
  end

  def start(attrs) when is_map(attrs) do
    with {:ok, scenario} <- Scenario.new(attrs), do: start(scenario)
  end

  defp start_runtime(supervisor, scenario, temp_dir) do
    paths = Zaik.Home.Mirror.Fixtures.paths(temp_dir)

    with {:ok, clock} <-
           start_child(
             supervisor,
             {Zaik.Home.Mirror.Clock, name: nil, now: scenario.now}
           ),
         clock_provider = {Zaik.Home.Mirror.Clock, clock},
         {:ok, device_store} <-
           start_child(
             supervisor,
             {Zaik.Home.DeviceStore, name: nil, clock: clock_provider, event_bus: false}
           ),
         {:ok, history_store} <-
           start_child(
             supervisor,
             {Zaik.Home.HistoryStore, name: nil, db_path: paths.home}
           ),
         {:ok, occupancy_tracker} <-
           start_child(
             supervisor,
             {Zaik.Home.OccupancyTracker,
              name: nil,
              event_bus: false,
              clock: clock_provider,
              absence_debounce_ms: 300_000,
              device_store: device_store,
              identity_store: history_store}
           ),
         {:ok, telemetry_store} <-
           start_child(
             supervisor,
             {Zaik.TelemetryStore, name: nil, db_path: paths.ops}
           ),
         {:ok, preset_store} <-
           start_child(
             supervisor,
             {Zaik.Home.DevicePresetStore,
              name: nil, db_path: paths.home, import_legacy_blind_presets?: false}
           ),
         {:ok, manual_override_store} <-
           start_child(
             supervisor,
             {Zaik.Home.Autonomy.ManualOverrideStore,
              name: nil, db_path: ":memory:", clock: clock_provider}
           ),
         {:ok, desired_state_store} <-
           start_child(
             supervisor,
             {Zaik.Home.Autonomy.DesiredStateStore,
              name: nil, db_path: ":memory:", clock: clock_provider}
           ),
         {:ok, action_budget_store} <-
           start_child(
             supervisor,
             {Zaik.Home.Autonomy.ActionBudgetStore,
              name: nil, db_path: paths.home, clock: clock_provider}
           ),
         {:ok, action_ledger} <-
           start_child(
             supervisor,
             {Zaik.Home.ActionLedger, name: nil, db_path: ":memory:", clock: clock_provider}
           ),
         {:ok, action_verifier} <-
           start_child(
             supervisor,
             {Zaik.Home.ActionVerifier,
              name: nil,
              timeout_ms: verification_timeout(scenario),
              wait_ms: verification_wait(scenario),
              retention_ms: 60_000,
              clock: clock_provider}
           ),
         {:ok, task_supervisor} <- start_child(supervisor, {Task.Supervisor, name: nil}),
         :ok <- load_entities(device_store, scenario),
         :ok <- load_presets(preset_store, scenario),
         :ok <-
           Zaik.Home.Mirror.Fixtures.load(scenario, %{
             history_store: history_store,
             telemetry_store: telemetry_store
           }),
         {:ok, store} <-
           start_child(
             supervisor,
             {Zaik.Home.Mirror.Store,
              name: nil,
              device_store: device_store,
              history_store: history_store,
              action_verifier: action_verifier,
              clock: clock_provider,
              faults: scenario.faults,
              events: scenario.events}
           ) do
      {:ok,
       %__MODULE__{
         scenario: scenario,
         supervisor: supervisor,
         temp_dir: temp_dir,
         clock: clock,
         device_store: device_store,
         occupancy_tracker: occupancy_tracker,
         history_store: history_store,
         telemetry_store: telemetry_store,
         home_db_path: paths.home,
         ops_db_path: paths.ops,
         preset_store: preset_store,
         manual_override_store: manual_override_store,
         desired_state_store: desired_state_store,
         action_budget_store: action_budget_store,
         action_verifier: action_verifier,
         action_ledger: action_ledger,
         task_supervisor: task_supervisor,
         store: store
       }}
    end
  end

  def context(%__MODULE__{} = mirror, extra \\ %{}) do
    Map.merge(
      %{
        clock: {Zaik.Home.Mirror.Clock, mirror.clock},
        device_store: mirror.device_store,
        occupancy_tracker: mirror.occupancy_tracker,
        preset_store: mirror.preset_store,
        manual_override_store: mirror.manual_override_store,
        desired_state_store: mirror.desired_state_store,
        action_budget_store: mirror.action_budget_store,
        history_store: mirror.history_store,
        telemetry_store: mirror.telemetry_store,
        sql_tool_opts: [
          telemetry_store: mirror.telemetry_store,
          home_db_path: mirror.home_db_path
        ],
        action_verifier: mirror.action_verifier,
        action_ledger: mirror.action_ledger,
        task_supervisor: mirror.task_supervisor,
        mirror_store: mirror.store,
        executor_opts: [modules: [Zaik.Home.Mirror.Executor]],
        verification_wait_ms: verification_wait(mirror.scenario),
        verification_timeout_ms: verification_timeout(mirror.scenario),
        mirror_scenario_id: mirror.scenario.id,
        mirror_scenario_fingerprint: Scenario.fingerprint(mirror.scenario)
      },
      extra
    )
  end

  def snapshot(%__MODULE__{} = mirror) do
    Zaik.Home.World.snapshot(nil,
      device_store: mirror.device_store,
      identity_store: mirror.history_store,
      clock: {Zaik.Home.Mirror.Clock, mirror.clock}
    )
  end

  def actions(%__MODULE__{} = mirror), do: Zaik.Home.Mirror.Store.actions(mirror.store)
  def reports(%__MODULE__{} = mirror), do: Zaik.Home.Mirror.Store.reports(mirror.store)

  def advance(%__MODULE__{} = mirror, milliseconds) do
    target_ms = Zaik.Home.Mirror.Clock.monotonic_ms(mirror.clock) + milliseconds
    advance_until(mirror, target_ms, 0)
  end

  def now(%__MODULE__{} = mirror), do: Zaik.Home.Mirror.Clock.now(mirror.clock)

  def side_effect_count(%__MODULE__{} = mirror),
    do: Zaik.Home.Mirror.Store.side_effect_count(mirror.store)

  def stop(%__MODULE__{} = mirror) do
    safe_stop(mirror.supervisor)
    cleanup_temp_dir(mirror.temp_dir)
    :ok
  end

  defp load_entities(device_store, scenario) do
    Enum.reduce_while(scenario.entities, :ok, fn entity, :ok ->
      name = value(entity, :name)
      payload = value(entity, :payload) || %{}
      metadata = value(entity, :metadata) || %{}
      area_id = value(entity, :area_id)
      entity_id = value(entity, :id)
      expected_capabilities = List.wrap(value(entity, :capabilities))

      metadata =
        metadata
        |> put_if("area_id", area_id)
        |> put_if("entity_id", entity_id)
        |> Map.put_new("source", "mirror")

      with {:ok, _device} <-
             Zaik.Home.DeviceStore.upsert_device(device_store, name, payload, metadata),
           {:ok, world_entity} <-
             Zaik.Home.World.get(entity_id || name, device_store: device_store),
           :ok <- expected_capabilities_present(world_entity, expected_capabilities) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_mirror_entity, name, reason}}}
      end
    end)
  end

  defp expected_capabilities_present(_entity, []), do: :ok

  defp expected_capabilities_present(entity, expected) do
    expected = Enum.map(expected, &to_string/1)
    missing = expected -- entity.capabilities

    if missing == [], do: :ok, else: {:error, {:missing_capabilities, missing}}
  end

  defp load_presets(preset_store, scenario) do
    Enum.each(scenario.presets, fn preset ->
      {:ok, _stored} =
        Zaik.Home.DevicePresetStore.put(
          value(preset, :device),
          value(preset, :name),
          value(preset, :capability),
          value(preset, :target),
          %{source: "mirror", metadata: value(preset, :metadata) || %{}},
          preset_store
        )
    end)

    :ok
  end

  defp advance_until(mirror, target_ms, fired) do
    current_ms = Zaik.Home.Mirror.Clock.monotonic_ms(mirror.clock)

    next_due_ms =
      case Zaik.Home.Mirror.Clock.pending(mirror.clock) do
        [%{due_ms: due_ms} | _] when due_ms <= target_ms -> due_ms
        _ -> target_ms
      end

    step = Zaik.Home.Mirror.Clock.advance(mirror.clock, next_due_ms - current_ms)
    :ok = Zaik.Home.Mirror.Store.barrier(mirror.store)
    :ok = Zaik.Home.ActionVerifier.barrier(mirror.action_verifier)
    total_fired = fired + step.fired

    if next_due_ms < target_ms do
      advance_until(mirror, target_ms, total_fired)
    else
      %{step | fired: total_fired}
    end
  end

  defp create_temp_dir(scenario) do
    suffix = System.unique_integer([:positive, :monotonic])
    safe_id = scenario.id |> String.replace(~r/[^a-zA-Z0-9_-]/, "-") |> String.slice(0, 60)
    path = Path.join([System.tmp_dir!(), "zaik-mirror", "#{safe_id}-#{suffix}"])

    case File.mkdir_p(path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:mirror_temp_dir_failed, reason}}
    end
  end

  defp cleanup_temp_dir(nil), do: :ok

  defp cleanup_temp_dir(path) do
    case File.rm_rf(path) do
      {:ok, _files} -> :ok
      {:error, reason, _file} -> {:error, reason}
    end
  end

  defp verification_timeout(scenario),
    do: value(scenario.metadata, :verification_timeout_ms) || 1_000

  defp verification_wait(scenario),
    do: value(scenario.metadata, :verification_wait_ms) || 200

  defp start_child(supervisor, child) do
    spec = Supervisor.child_spec(child, restart: :temporary)
    DynamicSupervisor.start_child(supervisor, spec)
  end

  defp safe_stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _reason -> :ok
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

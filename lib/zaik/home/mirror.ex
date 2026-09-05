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
    :device_store,
    :preset_store,
    :action_verifier,
    :action_ledger,
    :task_supervisor,
    :store
  ]

  @type t :: %__MODULE__{}

  def start(%Scenario{} = scenario) do
    with {:ok, supervisor} <- DynamicSupervisor.start_link(strategy: :one_for_one) do
      case start_runtime(supervisor, scenario) do
        {:ok, mirror} ->
          {:ok, mirror}

        {:error, reason} ->
          safe_stop(supervisor)
          {:error, reason}
      end
    end
  end

  def start(attrs) when is_map(attrs) do
    with {:ok, scenario} <- Scenario.new(attrs), do: start(scenario)
  end

  defp start_runtime(supervisor, scenario) do
    with {:ok, device_store} <- start_child(supervisor, {Zaik.Home.DeviceStore, name: nil}),
         {:ok, preset_store} <-
           start_child(
             supervisor,
             {Zaik.Home.DevicePresetStore, name: nil, db_path: ":memory:"}
           ),
         {:ok, action_ledger} <-
           start_child(supervisor, {Zaik.Home.ActionLedger, name: nil, db_path: ":memory:"}),
         {:ok, action_verifier} <-
           start_child(
             supervisor,
             {Zaik.Home.ActionVerifier,
              name: nil,
              timeout_ms: verification_timeout(scenario),
              wait_ms: verification_wait(scenario),
              retention_ms: 60_000}
           ),
         {:ok, task_supervisor} <- start_child(supervisor, {Task.Supervisor, name: nil}),
         :ok <- load_entities(device_store, scenario),
         :ok <- load_presets(preset_store, scenario),
         {:ok, store} <-
           start_child(
             supervisor,
             {Zaik.Home.Mirror.Store,
              name: nil,
              device_store: device_store,
              action_verifier: action_verifier,
              faults: scenario.faults}
           ) do
      {:ok,
       %__MODULE__{
         scenario: scenario,
         supervisor: supervisor,
         device_store: device_store,
         preset_store: preset_store,
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
        device_store: mirror.device_store,
        preset_store: mirror.preset_store,
        action_verifier: mirror.action_verifier,
        action_ledger: mirror.action_ledger,
        task_supervisor: mirror.task_supervisor,
        mirror_store: mirror.store,
        executor_opts: [modules: [Zaik.Home.Mirror.Executor]],
        verification_wait_ms: verification_wait(mirror.scenario),
        mirror_scenario_id: mirror.scenario.id,
        mirror_scenario_fingerprint: Scenario.fingerprint(mirror.scenario)
      },
      extra
    )
  end

  def snapshot(%__MODULE__{} = mirror) do
    Zaik.Home.World.snapshot(nil, device_store: mirror.device_store)
  end

  def actions(%__MODULE__{} = mirror), do: Zaik.Home.Mirror.Store.actions(mirror.store)

  def side_effect_count(%__MODULE__{} = mirror),
    do: Zaik.Home.Mirror.Store.side_effect_count(mirror.store)

  def stop(%__MODULE__{} = mirror) do
    safe_stop(mirror.supervisor)
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

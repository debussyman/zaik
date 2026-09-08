defmodule Zaik.Home.Mirror.Store do
  @moduledoc """
  Deterministic virtual adapter state plus action and ordered-report traces for
  one mirror run.
  """

  use GenServer

  def start_link(opts) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def accept(server, entity, capability, target, action_id) do
    GenServer.call(server, {:accept, entity, capability, target, action_id})
  end

  def commit(server, action_id), do: GenServer.call(server, {:commit, action_id})
  def actions(server), do: GenServer.call(server, :actions)
  def reports(server), do: GenServer.call(server, :reports)
  def side_effect_count(server), do: GenServer.call(server, :side_effect_count)
  def barrier(server), do: GenServer.call(server, :barrier)

  @impl true
  def init(opts) do
    state = %{
      device_store: Keyword.fetch!(opts, :device_store),
      history_store: Keyword.get(opts, :history_store),
      verifier: Keyword.fetch!(opts, :action_verifier),
      clock: Keyword.fetch!(opts, :clock),
      faults: normalize_faults(Keyword.get(opts, :faults, %{})),
      actions: %{},
      trace: [],
      report_trace: [],
      side_effect_count: 0
    }

    opts
    |> Keyword.get(:events, [])
    |> Enum.with_index()
    |> Enum.each(fn {event, index} ->
      Zaik.Time.send_after(
        state.clock,
        self(),
        {:scenario_event, index, event},
        fault_value(event, :at_ms, 0)
      )
    end)

    {:ok, state}
  end

  @impl true
  def handle_call({:accept, entity, capability, target, action_id}, _from, state) do
    fault = fault_for(state.faults, entity)

    action = %{
      action_id: action_id,
      entity_id: entity.id,
      device: entity.name,
      capability: capability,
      target: target,
      fault: fault,
      accepted_at: Zaik.Time.now(state.clock),
      status: "attempted"
    }

    case fault_type(fault) do
      :transport_failure ->
        action = %{action | status: "transport_failed"}
        {:reply, {:error, :mirror_transport_failure}, append_trace(state, action)}

      :executor_failure ->
        action = %{action | status: "executor_failed"}
        {:reply, {:error, :mirror_executor_failure}, append_trace(state, action)}

      _ ->
        action = %{action | status: "accepted"}

        state =
          state
          |> put_in([:actions, action_id], action)
          |> append_trace(action)
          |> Map.update!(:side_effect_count, &(&1 + 1))

        {:reply, {:ok, action}, state}
    end
  end

  def handle_call({:commit, action_id}, _from, state) do
    case Map.fetch(state.actions, action_id) do
      :error ->
        {:reply, {:error, :unknown_mirror_action}, state}

      {:ok, action} ->
        case fault_type(action.fault) do
          :never_converges ->
            {:reply, :ok, update_action_status(state, action_id, "accepted_unverified")}

          :delayed_convergence ->
            delay_ms = fault_value(action.fault, :delay_ms, 50)
            Zaik.Time.send_after(state.clock, self(), {:converge, action_id}, delay_ms)
            {:reply, :ok, update_action_status(state, action_id, "convergence_scheduled")}

          _ ->
            {:reply, :ok, converge(state, action_id)}
        end
    end
  end

  def handle_call(:barrier, _from, state), do: {:reply, :ok, state}
  def handle_call(:actions, _from, state), do: {:reply, state.trace, state}
  def handle_call(:reports, _from, state), do: {:reply, state.report_trace, state}
  def handle_call(:side_effect_count, _from, state), do: {:reply, state.side_effect_count, state}

  @impl true
  def handle_info({:converge, action_id}, state), do: {:noreply, converge(state, action_id)}

  def handle_info({:scenario_event, index, event}, state) do
    case normalize_atom(fault_value(event, :type, :none)) do
      :state_report ->
        device = fault_value(event, :device, nil)
        payload = fault_value(event, :payload, %{})
        observed_at = fault_value(event, :observed_at, Zaik.Time.now(state.clock))

        {state, _disposition} =
          deliver_report(state, device, payload, observed_at, %{
            source: "scenario",
            event_index: index
          })

        {:noreply, state}

      _unknown ->
        {:noreply, state}
    end
  end

  defp converge(state, action_id) do
    case Map.fetch(state.actions, action_id) do
      {:ok, action} ->
        report = transition_payload(action.target, action.fault)
        observed_at = Zaik.Time.now(state.clock)

        {state, disposition} =
          deliver_report(state, action.device, report, observed_at, %{
            source: "action",
            action_id: action_id
          })

        status = if disposition == :accepted, do: "reported", else: "report_ignored"
        update_action_status(state, action_id, status)

      :error ->
        state
    end
  end

  defp deliver_report(state, device, payload, observed_at, attrs) do
    result =
      Zaik.Home.DeviceStore.upsert_device(
        state.device_store,
        device,
        payload,
        %{"source" => "mirror", "observed_at" => observed_at}
      )

    disposition =
      case result do
        {:ok, current_device} ->
          record_history(state.history_store, current_device, observed_at)

          Zaik.Home.ActionVerifier.observe(
            device,
            payload,
            observed_at,
            server: state.verifier
          )

          :accepted

        {:ignored, reason} ->
          reason
      end

    trace = %{
      device: device,
      payload: payload,
      observed_at: DateTime.to_iso8601(observed_at),
      delivered_at: Zaik.Time.now(state.clock) |> DateTime.to_iso8601(),
      disposition: to_string(disposition),
      source: attrs.source,
      action_id: Map.get(attrs, :action_id),
      event_index: Map.get(attrs, :event_index)
    }

    {%{state | report_trace: state.report_trace ++ [trace]}, disposition}
  end

  defp record_history(nil, _device, _observed_at), do: :ok

  defp record_history(history_store, device, observed_at) do
    Zaik.Home.HistoryStore.record_device(
      history_store,
      device.friendly_name,
      device.payload,
      device.metadata,
      observed_at: observed_at
    )
  end

  defp transition_payload(%{"position" => position}, fault) do
    %{"position" => fault_value(fault, :reported_position, position), "state" => "STOP"}
  end

  defp transition_payload(%{"state" => "OPEN"}, fault),
    do: %{"state" => "OPEN", "position" => fault_value(fault, :reported_position, 0)}

  defp transition_payload(%{"state" => "CLOSE"}, fault),
    do: %{"state" => "CLOSE", "position" => fault_value(fault, :reported_position, 100)}

  defp transition_payload(%{"state" => "STOP"}, _fault), do: %{"state" => "STOP"}
  defp transition_payload(target, _fault), do: target

  defp update_action_status(state, action_id, status) do
    update_in(state, [:actions, action_id], fn
      nil -> nil
      action -> %{action | status: status}
    end)
  end

  defp append_trace(state, action), do: %{state | trace: state.trace ++ [public_action(action)]}

  defp public_action(action) do
    Map.update!(action, :accepted_at, &DateTime.to_iso8601/1)
  end

  defp normalize_faults(faults) do
    Map.new(faults, fn {key, fault} -> {normalize(key), fault} end)
  end

  defp fault_for(faults, entity) do
    Map.get(faults, normalize(entity.id)) || Map.get(faults, normalize(entity.name)) || :none
  end

  defp fault_type(fault) when is_atom(fault), do: fault

  defp fault_type(fault) when is_map(fault),
    do: fault_value(fault, :type, :none) |> normalize_atom()

  defp fault_type(_fault), do: :none

  defp fault_value(fault, key, default) when is_map(fault),
    do: Map.get(fault, key, Map.get(fault, to_string(key), default))

  defp fault_value(_fault, _key, default), do: default

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) do
    case normalize(value) do
      "transport_failure" -> :transport_failure
      "executor_failure" -> :executor_failure
      "never_converges" -> :never_converges
      "delayed_convergence" -> :delayed_convergence
      "state_report" -> :state_report
      _ -> :none
    end
  end

  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
end

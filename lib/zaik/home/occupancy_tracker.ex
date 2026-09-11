defmodule Zaik.Home.OccupancyTracker do
  @moduledoc """
  Debounces canonical presence observations into area occupancy transitions.

  A positive observation enters immediately. The last negative observation
  moves the area to `possibly_absent`; only an uninterrupted settle window can
  move it to `vacant`. Timer generations make stale virtual or production
  timers harmless.
  """

  use GenServer

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, Keyword.put_new(server_opts, :name, __MODULE__))
  end

  def status(area, server \\ __MODULE__) when is_binary(area),
    do: GenServer.call(server, {:status, normalize(area)})

  def all(server \\ __MODULE__), do: GenServer.call(server, :all)

  @impl true
  def init(opts) do
    bus = Keyword.get(opts, :event_bus, Zaik.Home.EventBus)

    if process_available?(bus) do
      :ok = Zaik.Home.EventBus.subscribe(bus, self())
    end

    {:ok,
     %{
       event_bus: bus,
       clock: Keyword.get(opts, :clock),
       absence_debounce_ms: Keyword.get(opts, :absence_debounce_ms, 5 * 60_000),
       device_store: Keyword.get(opts, :device_store, Zaik.Home.DeviceStore),
       identity_store: Keyword.get(opts, :identity_store, Zaik.Home.HistoryStore),
       areas: %{},
       sensors: %{},
       generations: %{}
     }}
  end

  @impl true
  def handle_call({:status, area}, _from, state) do
    {:reply, Map.get(state.areas, area, unknown(area)), state}
  end

  def handle_call(:all, _from, state), do: {:reply, state.areas, state}

  @impl true
  def handle_info({:zaik_home_event, %{type: :device_observed} = event}, state) do
    case presence_observation(event) do
      {:ok, detected} -> {:noreply, observe(state, event, detected)}
      :ignore -> {:noreply, state}
    end
  end

  def handle_info({:occupancy_vacate, area, generation}, state) do
    if Map.get(state.generations, area) == generation and not area_detected?(state, area) do
      now = Zaik.Time.now(state.clock)
      previous = Map.get(state.areas, area, unknown(area))

      occupancy = %{
        area: area,
        status: "vacant",
        transition: "vacant",
        confidence: 0.9,
        observed_at: previous.observed_at,
        transitioned_at: DateTime.to_iso8601(now),
        evidence_count: sensor_count(state, area)
      }

      state = put_in(state, [:areas, area], occupancy)
      publish_transition(state, occupancy)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp observe(state, event, detected) do
    area = event_area(event, state)
    device = normalize(event.device)
    observed_at = format_time(Map.get(event, :observed_at), state.clock)

    sensors =
      Map.update(state.sensors, area, %{device => detected}, &Map.put(&1, device, detected))

    state = %{state | sensors: sensors}
    generation = Map.get(state.generations, area, 0) + 1
    state = put_in(state, [:generations, area], generation)
    previous = Map.get(state.areas, area, unknown(area))

    cond do
      area_detected?(state, area) ->
        transition = if previous.status == "occupied", do: "occupied", else: "entered"

        occupancy = %{
          area: area,
          status: "occupied",
          transition: transition,
          confidence: 1.0,
          observed_at: observed_at,
          transitioned_at: transition_time(previous, transition, state.clock),
          evidence_count: detected_count(state, area)
        }

        state = put_in(state, [:areas, area], occupancy)
        publish_transition(state, occupancy)
        state

      true ->
        occupancy = %{
          area: area,
          status: "possibly_absent",
          transition: "possibly_absent",
          confidence: 0.5,
          observed_at: observed_at,
          transitioned_at: format_time(nil, state.clock),
          evidence_count: sensor_count(state, area)
        }

        Zaik.Time.send_after(
          state.clock,
          self(),
          {:occupancy_vacate, area, generation},
          state.absence_debounce_ms
        )

        state = put_in(state, [:areas, area], occupancy)
        publish_transition(state, occupancy)
        state
    end
  end

  defp publish_transition(%{event_bus: false}, _occupancy), do: :ok
  defp publish_transition(%{event_bus: nil}, _occupancy), do: :ok

  defp publish_transition(state, occupancy) do
    if process_available?(state.event_bus) do
      Zaik.Home.EventBus.publish(
        %{
          type: :occupancy_changed,
          area: occupancy.area,
          status: occupancy.status,
          transition: occupancy.transition,
          confidence: occupancy.confidence,
          changed_keys: ["presence"],
          observed_at: occupancy.observed_at
        },
        state.event_bus
      )
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp presence_observation(event) do
    if "presence" in List.wrap(Map.get(event, :changed_keys)) do
      case get_in(event, [:payload, "presence"]) do
        value when is_boolean(value) -> {:ok, value}
        _ -> :ignore
      end
    else
      :ignore
    end
  end

  defp event_area(event, state) do
    metadata = Map.get(event, :metadata, %{})

    case Map.get(metadata, "area_id") || Map.get(metadata, :area_id) do
      area when is_binary(area) and area != "" ->
        normalize(area)

      _ ->
        case Zaik.Home.World.get(event.device,
               device_store: state.device_store,
               identity_store: state.identity_store
             ) do
          {:ok, %{area_id: area}} when is_binary(area) and area != "" -> normalize(area)
          _ -> normalize(event.device)
        end
    end
  catch
    :exit, _reason -> normalize(event.device)
  end

  defp area_detected?(state, area),
    do: state.sensors |> Map.get(area, %{}) |> Map.values() |> Enum.any?(&(&1 == true))

  defp detected_count(state, area),
    do: state.sensors |> Map.get(area, %{}) |> Map.values() |> Enum.count(&(&1 == true))

  defp sensor_count(state, area), do: state.sensors |> Map.get(area, %{}) |> map_size()

  defp transition_time(previous, "occupied", _clock), do: previous.transitioned_at
  defp transition_time(_previous, _transition, clock), do: format_time(nil, clock)

  defp unknown(area) do
    %{
      area: area,
      status: "unknown",
      transition: nil,
      confidence: 0.0,
      observed_at: nil,
      transitioned_at: nil,
      evidence_count: 0
    }
  end

  defp format_time(%DateTime{} = time, _clock), do: DateTime.to_iso8601(time)
  defp format_time(time, _clock) when is_binary(time), do: time
  defp format_time(_time, clock), do: clock |> Zaik.Time.now() |> DateTime.to_iso8601()
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()

  defp process_available?(server) when is_pid(server), do: Process.alive?(server)
  defp process_available?(server) when is_atom(server), do: not is_nil(Process.whereis(server))
  defp process_available?(_server), do: false
end

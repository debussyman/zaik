defmodule Zaik.Messaging.SignalPoller do
  @moduledoc """
  Polls Signal messages and routes allowed messages through `Zaik.Ingress`.
  """

  use GenServer
  require Logger

  @seen_limit 500

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def state(server \\ __MODULE__), do: GenServer.call(server, :state)
  def poll_now(server \\ __MODULE__), do: GenServer.call(server, :poll_now)

  @impl true
  def init(opts) do
    config = Map.merge(Zaik.Messaging.SignalClient.config(), Map.new(opts))

    if config.enabled do
      account = Map.get(config, :account)

      if is_nil(account) or account == "" do
        Logger.warning("Signal poller enabled but no account configured; ignoring")
        :ignore
      else
        state = %{
          account: account,
          allowed_senders: MapSet.new(Map.get(config, :allowed_senders, [])),
          poll_interval_ms: Map.get(config, :poll_interval_ms, 5_000),
          seen: MapSet.new(),
          seen_order: [],
          client: Map.get(config, :client, Zaik.Messaging.SignalClient)
        }

        schedule_poll(state)
        {:ok, state}
      end
    else
      :ignore
    end
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call(:poll_now, _from, state) do
    {summary, state} = poll(state)
    {:reply, summary, state}
  end

  @impl true
  def handle_info(:poll, state) do
    {_summary, state} = poll(state)
    schedule_poll(state)
    {:noreply, state}
  end

  def normalize_messages(payload) do
    payload
    |> unwrap_messages()
    |> Enum.flat_map(&normalize_message/1)
  end

  def allowed_sender?(allowed_senders, sender) do
    MapSet.member?(allowed_senders, sender)
  end

  def respond_to_signal_message?(response) when is_binary(response) do
    not String.starts_with?(response, "Unknown command.")
  end

  def respond_to_signal_message?(_response), do: false

  defp poll(state) do
    case state.client.receive(state.account) do
      {:ok, payload} ->
        payload
        |> normalize_messages()
        |> Enum.reduce(
          {%{processed: 0, ignored: 0, rejected: 0, errors: 0}, state},
          &handle_message/2
        )

      {:error, reason} ->
        Logger.warning("Signal poll failed: #{inspect(reason)}")
        {%{processed: 0, ignored: 0, rejected: 0, errors: 1}, state}
    end
  end

  defp handle_message(message, {summary, state}) do
    cond do
      MapSet.member?(state.seen, message.id) ->
        {%{summary | ignored: summary.ignored + 1}, state}

      not allowed_sender?(state.allowed_senders, message.sender) ->
        Logger.warning(
          "Rejected Signal message from non-allowlisted sender #{inspect(message.sender)}"
        )

        {%{summary | rejected: summary.rejected + 1}, remember_seen(state, message.id)}

      true ->
        case process_message(state, message) do
          :ok ->
            {%{summary | processed: summary.processed + 1}, remember_seen(state, message.id)}

          {:error, reason} ->
            Logger.warning("Signal message processing failed: #{inspect(reason)}")
            {%{summary | errors: summary.errors + 1}, remember_seen(state, message.id)}
        end
    end
  end

  defp process_message(state, message) do
    ingress_message = %Zaik.Ingress.Message{
      channel: :signal,
      sender_id: message.sender,
      text: message.body,
      timestamp: message.timestamp,
      session_key: message.sender,
      metadata: %{
        sender: message.sender,
        signal_timestamp: message.timestamp
      }
    }

    with {:ok, %{response: response}} <- Zaik.Ingress.handle_message(ingress_message) do
      if respond_to_signal_message?(response) do
        send_result = state.client.send_message(message.sender, response, state.account)

        case send_result do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:send_failed, reason}}
        end
      else
        :ok
      end
    end
  end

  defp schedule_poll(state) do
    Process.send_after(self(), :poll, state.poll_interval_ms)
  end

  defp remember_seen(state, id) do
    seen = MapSet.put(state.seen, id)
    seen_order = [id | state.seen_order]

    if length(seen_order) > @seen_limit do
      {keep, drop} = Enum.split(seen_order, @seen_limit)
      %{state | seen: Enum.reduce(drop, seen, &MapSet.delete(&2, &1)), seen_order: keep}
    else
      %{state | seen: seen, seen_order: seen_order}
    end
  end

  defp unwrap_messages(payload) when is_list(payload), do: payload
  defp unwrap_messages(%{"messages" => messages}) when is_list(messages), do: messages
  defp unwrap_messages(%{"envelopes" => messages}) when is_list(messages), do: messages
  defp unwrap_messages(%{"results" => messages}) when is_list(messages), do: messages
  defp unwrap_messages(map) when is_map(map), do: [map]
  defp unwrap_messages(_payload), do: []

  defp normalize_message(raw) when is_map(raw) do
    envelope = Map.get(raw, "envelope", raw)
    sync_message = Map.get(envelope, "syncMessage") || Map.get(raw, "syncMessage") || %{}
    sent_message = Map.get(sync_message, "sentMessage") || %{}

    data_message =
      Map.get(envelope, "dataMessage") || Map.get(raw, "dataMessage") || sent_message || %{}

    sender =
      first_present([
        Map.get(envelope, "sourceNumber"),
        Map.get(envelope, "source"),
        Map.get(sent_message, "destination"),
        Map.get(raw, "sourceNumber"),
        Map.get(raw, "source"),
        Map.get(raw, "from")
      ])

    body =
      first_present([
        Map.get(data_message, "message"),
        Map.get(sent_message, "message"),
        Map.get(envelope, "message"),
        Map.get(raw, "message"),
        Map.get(raw, "body"),
        Map.get(raw, "text")
      ])

    timestamp =
      first_present([
        Map.get(envelope, "timestamp"),
        Map.get(data_message, "timestamp"),
        Map.get(sent_message, "timestamp"),
        Map.get(raw, "timestamp"),
        Map.get(raw, "id")
      ])

    if present?(sender) and present?(body) do
      id =
        first_present([
          Map.get(raw, "id"),
          Map.get(envelope, "serverReceivedTimestamp"),
          timestamp && "#{sender}:#{timestamp}:#{body}"
        ])

      [%{id: to_string(id), sender: sender, body: body, timestamp: timestamp}]
    else
      []
    end
  end

  defp normalize_message(_raw), do: []

  defp first_present(values), do: Enum.find(values, &present?/1)
  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end

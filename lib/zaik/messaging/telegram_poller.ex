defmodule Zaik.Messaging.TelegramPoller do
  @moduledoc """
  Polls Telegram Bot API updates and routes allowed messages to `Zaik.ChatRouter`.
  """

  use GenServer
  require Logger

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def state(server \\ __MODULE__), do: GenServer.call(server, :state)
  def poll_now(server \\ __MODULE__), do: GenServer.call(server, :poll_now)

  @impl true
  def init(opts) do
    config = Map.merge(Zaik.Messaging.TelegramClient.config(), Map.new(opts))

    if config.enabled do
      if is_nil(config.bot_token) or config.bot_token == "" do
        Logger.warning("Telegram poller enabled but no bot token configured; ignoring")
        :ignore
      else
        state = %{
          offset: Map.get(config, :offset),
          allowed_user_ids:
            MapSet.new(Enum.map(Map.get(config, :allowed_user_ids, []), &to_string/1)),
          allowed_chat_ids:
            MapSet.new(Enum.map(Map.get(config, :allowed_chat_ids, []), &to_string/1)),
          poll_interval_ms: Map.get(config, :poll_interval_ms, 1_000),
          long_poll_timeout_seconds: Map.get(config, :long_poll_timeout_seconds, 10),
          require_direct_addressing: Map.get(config, :require_direct_addressing, false),
          group_trigger: Map.get(config, :group_trigger, "zaik"),
          bot_username: Map.get(config, :bot_username),
          client: Map.get(config, :client, Zaik.Messaging.TelegramClient)
        }

        schedule_poll(0)
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
    schedule_poll(state.poll_interval_ms)
    {:noreply, state}
  end

  def normalize_updates(updates) when is_list(updates) do
    updates
    |> Enum.flat_map(&normalize_update/1)
  end

  def normalize_updates(_updates), do: []

  def allowed_message?(state, message) do
    cond do
      MapSet.member?(state.allowed_user_ids, message.sender_id) -> true
      MapSet.member?(state.allowed_chat_ids, message.chat_id) -> true
      true -> false
    end
  end

  def addressed_text(message, state) do
    if message.chat_type in ["group", "supergroup"] do
      if Map.get(state, :require_direct_addressing, false) do
        strip_group_trigger(message.text, state.group_trigger, state.bot_username)
      else
        ambient_group_text(message.text, state.group_trigger, state.bot_username)
      end
    else
      {:ok, message.text}
    end
  end

  defp poll(state) do
    case state.client.get_updates(state.offset,
           timeout_seconds: state.long_poll_timeout_seconds
         ) do
      {:ok, updates} ->
        messages = normalize_updates(updates)

        {summary, state} =
          Enum.reduce(
            messages,
            {%{processed: 0, ignored: 0, rejected: 0, errors: 0}, state},
            fn message, {summary, state} ->
              handle_message(message, {summary, state})
            end
          )

        max_update_id =
          updates
          |> Enum.map(&Map.get(&1, "update_id"))
          |> Enum.reject(&is_nil/1)
          |> Enum.max(fn -> nil end)

        state =
          if is_nil(max_update_id) do
            state
          else
            %{state | offset: max_update_id + 1}
          end

        {summary, state}

      {:error, reason} ->
        Logger.warning("Telegram poll failed: #{inspect(reason)}")
        {%{processed: 0, ignored: 0, rejected: 0, errors: 1}, state}
    end
  end

  defp handle_message(message, {summary, state}) do
    cond do
      not allowed_message?(state, message) ->
        Logger.warning(
          "Rejected Telegram message from user #{inspect(message.sender_id)} in chat #{inspect(message.chat_id)}"
        )

        {%{summary | rejected: summary.rejected + 1}, state}

      true ->
        case addressed_text(message, state) do
          :ignore ->
            {%{summary | ignored: summary.ignored + 1}, state}

          {:ok, text} ->
            case process_message(state, %{message | text: text}) do
              :ok ->
                {%{summary | processed: summary.processed + 1}, state}

              {:error, reason} ->
                Logger.warning("Telegram message processing failed: #{inspect(reason)}")
                {%{summary | errors: summary.errors + 1}, state}
            end
        end
    end
  end

  defp process_message(state, message) do
    session_key = session_key(message)

    with {:ok, session} <-
           Zaik.Messaging.SessionMapper.get_or_create_session(:telegram, session_key),
         {:ok, _entry_id} <-
           Zaik.MemoryStore.append_message(session.id, :user, message.text,
             metadata: %{
               sender_id: message.sender_id,
               sender_username: message.sender_username,
               sender_name: message.sender_name,
               chat_id: message.chat_id,
               chat_type: message.chat_type,
               chat_title: message.chat_title,
               telegram_message_id: message.message_id,
               telegram_update_id: message.update_id,
               channel: :telegram
             }
           ) do
      context = %{
        channel: :telegram,
        sender: message.sender_id,
        sender_id: message.sender_id,
        chat_id: message.chat_id,
        chat_type: message.chat_type,
        session_id: session.id
      }

      response = Zaik.ChatRouter.process(message.text, context)

      send_result =
        state.client.send_message(message.chat_id, response,
          reply_to_message_id: message.message_id
        )

      Zaik.MemoryStore.append_message(session.id, :agent, response,
        metadata: %{channel: :telegram, send_result: inspect(send_result)}
      )

      case send_result do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:send_failed, reason}}
      end
    end
  end

  defp normalize_update(%{"update_id" => update_id} = update) do
    message = Map.get(update, "message") || %{}
    text = Map.get(message, "text")

    if is_binary(text) and text != "" do
      from = Map.get(message, "from") || %{}
      chat = Map.get(message, "chat") || %{}

      [
        %{
          update_id: update_id,
          message_id: Map.get(message, "message_id"),
          sender_id: Map.get(from, "id") |> to_string_or_nil(),
          sender_username: Map.get(from, "username"),
          sender_name: display_name(from),
          chat_id: Map.get(chat, "id") |> to_string_or_nil(),
          chat_type: Map.get(chat, "type", "private"),
          chat_title: Map.get(chat, "title"),
          text: text,
          timestamp: Map.get(message, "date")
        }
      ]
      |> Enum.reject(&(is_nil(&1.sender_id) or is_nil(&1.chat_id)))
    else
      []
    end
  end

  defp normalize_update(_update), do: []

  defp strip_group_trigger(text, trigger, bot_username) do
    trimmed = String.trim(text)
    downcased = String.downcase(trimmed)
    trigger = trigger |> to_string() |> String.trim() |> String.downcase()
    username = normalize_username(bot_username)
    mention = if username in [nil, ""], do: nil, else: "@" <> username
    slash_trigger = if trigger == "", do: nil, else: "/" <> trigger
    slash_mention = if mention && trigger != "", do: slash_trigger <> mention, else: nil

    cond do
      slash_mention && String.starts_with?(downcased, slash_mention) ->
        {:ok,
         trimmed
         |> String.slice(String.length(slash_mention)..-1//1)
         |> strip_addressing_separator()}

      slash_trigger && String.starts_with?(downcased, slash_trigger) ->
        {:ok,
         trimmed
         |> String.slice(String.length(slash_trigger)..-1//1)
         |> strip_addressing_separator()}

      mention && String.starts_with?(downcased, mention) ->
        {:ok,
         trimmed
         |> String.slice(String.length(mention)..-1//1)
         |> strip_addressing_separator()}

      trigger != "" and String.starts_with?(downcased, trigger) ->
        {:ok,
         trimmed
         |> String.slice(String.length(trigger)..-1//1)
         |> strip_addressing_separator()}

      true ->
        :ignore
    end
  end

  defp ambient_group_text(text, trigger, bot_username) do
    if mentions_someone_else?(text, bot_username) do
      :ignore
    else
      case strip_group_trigger(text, trigger, bot_username) do
        {:ok, stripped} -> {:ok, stripped}
        :ignore -> {:ok, String.trim(text)}
      end
    end
  end

  defp mentions_someone_else?(text, bot_username) do
    bot_username = normalize_username(bot_username)

    text
    |> mention_usernames()
    |> Enum.any?(fn username -> bot_username in [nil, ""] or username != bot_username end)
  end

  defp mention_usernames(text) do
    ~r/(?:^|[^\w.])@([A-Za-z][A-Za-z0-9_]{2,31})\b/
    |> Regex.scan(text)
    |> Enum.map(fn [_match, username] -> String.downcase(username) end)
  end

  defp normalize_username(nil), do: nil

  defp normalize_username(username) do
    username
    |> to_string()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
  end

  defp strip_addressing_separator(text) do
    text
    |> String.trim()
    |> String.trim_leading(":")
    |> String.trim_leading(",")
    |> String.trim()
  end

  defp session_key(%{chat_type: chat_type, chat_id: chat_id})
       when chat_type in ["group", "supergroup"],
       do: "chat:#{chat_id}"

  defp session_key(%{sender_id: sender_id}), do: "user:#{sender_id}"

  defp schedule_poll(delay_ms) do
    Process.send_after(self(), :poll, delay_ms)
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp display_name(from) do
    [Map.get(from, "first_name"), Map.get(from, "last_name")]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> Map.get(from, "username")
      name -> name
    end
  end
end

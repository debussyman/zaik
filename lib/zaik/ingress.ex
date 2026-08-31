defmodule Zaik.Ingress do
  @moduledoc """
  Shared inbound message handling for chat/messaging adapters.

  Adapters own protocol concerns: polling, allowlists, addressing, and sending
  replies. This module owns Zaik concerns: session mapping, memory writes,
  routing, and agent-reply memory writes.
  """

  alias Zaik.Ingress.Message

  @type result :: %{
          session: Zaik.Session.t(),
          response: String.t(),
          context: map(),
          user_entry_id: String.t(),
          agent_entry_id: String.t() | nil
        }

  @doc "Handle one normalized inbound message and return the reply text/context."
  @spec handle_message(Message.t() | map(), keyword()) :: {:ok, result()} | {:error, term()}
  def handle_message(message, opts \\ []) do
    message = Message.new(message)
    router = Keyword.get(opts, :router, Zaik.ChatRouter)

    with :ok <- validate_message(message),
         {:ok, session} <-
           Zaik.Messaging.SessionMapper.get_or_create_session(
             message.channel,
             session_key(message)
           ),
         {:ok, user_entry_id} <- append_user_message(session.id, message) do
      context = context(message, session)
      response = router.process(message.text, context)

      case append_agent_message(session.id, message, response) do
        {:ok, agent_entry_id} ->
          {:ok,
           %{
             session: session,
             response: response,
             context: context,
             user_entry_id: user_entry_id,
             agent_entry_id: agent_entry_id
           }}

        {:error, reason} ->
          {:error, {:agent_memory_append_failed, reason}}
      end
    end
  end

  defp validate_message(%Message{} = message) do
    cond do
      not is_binary(message.text) or String.trim(message.text) == "" ->
        {:error, :empty_text}

      not is_atom(message.channel) ->
        {:error, :invalid_channel}

      not identity_available?(message) ->
        {:error, :missing_identity}

      true ->
        :ok
    end
  end

  defp identity_available?(%Message{session_key: session_key}) when is_binary(session_key),
    do: true

  defp identity_available?(%Message{chat_type: chat_type, chat_id: chat_id})
       when chat_type in ["group", "supergroup"] and is_binary(chat_id),
       do: true

  defp identity_available?(%Message{sender_id: sender_id}) when is_binary(sender_id), do: true
  defp identity_available?(%Message{chat_id: chat_id}) when is_binary(chat_id), do: true
  defp identity_available?(_message), do: false

  defp append_user_message(session_id, message) do
    Zaik.MemoryStore.append_message(session_id, :user, message.text,
      metadata: user_metadata(message)
    )
  end

  defp append_agent_message(session_id, message, response) when is_binary(response) do
    Zaik.MemoryStore.append_message(session_id, :agent, response,
      metadata: %{channel: message.channel, ingress: true}
    )
  end

  defp append_agent_message(_session_id, _message, _response), do: {:ok, nil}

  defp context(message, session) do
    %{
      channel: message.channel,
      sender: message.sender_id,
      sender_id: message.sender_id,
      chat_id: message.chat_id,
      chat_type: message.chat_type,
      session_id: session.id
    }
  end

  defp user_metadata(message) do
    message.metadata
    |> Map.merge(%{
      channel: message.channel,
      sender: message.sender_id,
      sender_id: message.sender_id,
      sender_username: message.sender_username,
      sender_name: message.sender_name,
      chat_id: message.chat_id,
      chat_type: message.chat_type,
      chat_title: message.chat_title,
      message_id: message.message_id,
      update_id: message.update_id,
      timestamp: message.timestamp
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp session_key(%Message{session_key: session_key}) when is_binary(session_key),
    do: session_key

  defp session_key(%Message{chat_type: chat_type, chat_id: chat_id})
       when chat_type in ["group", "supergroup"] and is_binary(chat_id),
       do: "chat:#{chat_id}"

  defp session_key(%Message{sender_id: sender_id}) when is_binary(sender_id),
    do: "user:#{sender_id}"

  defp session_key(%Message{chat_id: chat_id}) when is_binary(chat_id), do: "chat:#{chat_id}"
end

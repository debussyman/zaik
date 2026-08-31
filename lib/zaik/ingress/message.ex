defmodule Zaik.Ingress.Message do
  @moduledoc """
  Normalized inbound chat/message event used by messaging adapters.

  Protocol adapters should translate their native update shape into this struct,
  then call `Zaik.Ingress.handle_message/2`. Adapters remain responsible for
  protocol-specific allowlists, addressing rules, polling, and sending replies.
  """

  @type t :: %__MODULE__{
          channel: atom(),
          sender_id: String.t() | nil,
          sender_username: String.t() | nil,
          sender_name: String.t() | nil,
          chat_id: String.t() | nil,
          chat_type: String.t() | nil,
          chat_title: String.t() | nil,
          text: String.t(),
          message_id: String.t() | integer() | nil,
          update_id: String.t() | integer() | nil,
          timestamp: term(),
          session_key: String.t() | nil,
          metadata: map()
        }

  defstruct [
    :channel,
    :sender_id,
    :sender_username,
    :sender_name,
    :chat_id,
    :chat_type,
    :chat_title,
    :text,
    :message_id,
    :update_id,
    :timestamp,
    :session_key,
    metadata: %{}
  ]

  @doc "Normalize a map/struct into `Zaik.Ingress.Message`."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      channel: normalize_channel(value(attrs, :channel) || :unknown),
      sender_id: string_or_nil(value(attrs, :sender_id) || value(attrs, :sender)),
      sender_username: string_or_nil(value(attrs, :sender_username)),
      sender_name: string_or_nil(value(attrs, :sender_name)),
      chat_id: string_or_nil(value(attrs, :chat_id)),
      chat_type: string_or_nil(value(attrs, :chat_type)),
      chat_title: string_or_nil(value(attrs, :chat_title)),
      text: to_string(value(attrs, :text) || value(attrs, :body) || ""),
      message_id: value(attrs, :message_id),
      update_id: value(attrs, :update_id),
      timestamp: value(attrs, :timestamp),
      session_key: string_or_nil(value(attrs, :session_key)),
      metadata: value(attrs, :metadata) || %{}
    }
  end

  defp value(%__MODULE__{} = message, key), do: Map.get(message, key)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp normalize_channel(channel) when is_atom(channel), do: channel

  defp normalize_channel(channel) do
    channel
    |> to_string()
    |> String.trim()
    |> String.to_atom()
  end

  defp string_or_nil(nil), do: nil
  defp string_or_nil(""), do: nil
  defp string_or_nil(value), do: to_string(value)
end

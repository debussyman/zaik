defmodule Zaik.Messaging.SessionMapper do
  @moduledoc """
  Maps messaging identities to durable Zaik sessions.
  """

  def get_or_create_session(channel, sender) when is_atom(channel) and is_binary(sender) do
    channel_text = to_string(channel)
    cwd = "#{channel_text}:#{sender}"

    case find_session(channel, channel_text, sender, cwd) do
      nil ->
        Zaik.SessionStore.create(
          scope: channel,
          cwd: cwd,
          metadata: %{"channel" => channel_text, "sender" => sender}
        )

      session ->
        {:ok, session}
    end
  end

  defp find_session(channel, channel_text, sender, cwd) do
    Zaik.SessionStore.list(scope: channel)
    |> Enum.find(fn session ->
      session.cwd == cwd or
        metadata_value(session.metadata, "sender") == sender or
        (metadata_value(session.metadata, "channel") == channel_text and session.cwd == cwd)
    end)
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, String.to_atom(key))
  end

  defp metadata_value(_metadata, _key), do: nil
end

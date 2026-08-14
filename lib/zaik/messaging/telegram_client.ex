defmodule Zaik.Messaging.TelegramClient do
  @moduledoc """
  Minimal Telegram Bot API client for Zaik messaging ingress.
  """

  @default_api_url "https://api.telegram.org"

  def get_updates(offset \\ nil, opts \\ []) do
    with {:ok, token} <- require_value(config().bot_token, :bot_token) do
      payload = %{
        timeout: Keyword.get(opts, :timeout_seconds, config().long_poll_timeout_seconds),
        allowed_updates: ["message"]
      }

      payload =
        if is_nil(offset) do
          payload
        else
          Map.put(payload, :offset, offset)
        end

      request(:post, bot_url(token, "/getUpdates"), payload)
    end
  end

  def send_message(chat_id, text, opts \\ []) do
    with {:ok, token} <- require_value(config().bot_token, :bot_token),
         {:ok, _chat_id} <- require_value(chat_id, :chat_id) do
      payload = %{
        chat_id: chat_id,
        text: text,
        disable_web_page_preview: true
      }

      payload =
        case Keyword.get(opts, :reply_to_message_id) do
          nil -> payload
          message_id -> Map.put(payload, :reply_to_message_id, message_id)
        end

      request(:post, bot_url(token, "/sendMessage"), payload)
    end
  end

  def get_me do
    with {:ok, token} <- require_value(config().bot_token, :bot_token) do
      request(:get, bot_url(token, "/getMe"))
    end
  end

  def config do
    app_config = Application.get_env(:zaik, :telegram, [])

    %{
      enabled: env_bool("ZAIK_TELEGRAM_ENABLED", Keyword.get(app_config, :enabled, false)),
      bot_token: System.get_env("ZAIK_TELEGRAM_BOT_TOKEN") || Keyword.get(app_config, :bot_token),
      bot_username:
        System.get_env("ZAIK_TELEGRAM_BOT_USERNAME") || Keyword.get(app_config, :bot_username),
      api_url:
        System.get_env("ZAIK_TELEGRAM_API_URL") ||
          Keyword.get(app_config, :api_url, @default_api_url),
      allowed_user_ids:
        env_list("ZAIK_TELEGRAM_ALLOWED_USER_IDS") ||
          Keyword.get(app_config, :allowed_user_ids, []),
      allowed_chat_ids:
        env_list("ZAIK_TELEGRAM_ALLOWED_CHAT_IDS") ||
          Keyword.get(app_config, :allowed_chat_ids, []),
      poll_interval_ms:
        env_integer("ZAIK_TELEGRAM_POLL_INTERVAL_MS") ||
          Keyword.get(app_config, :poll_interval_ms, 1_000),
      long_poll_timeout_seconds:
        env_integer("ZAIK_TELEGRAM_LONG_POLL_TIMEOUT_SECONDS") ||
          Keyword.get(app_config, :long_poll_timeout_seconds, 10),
      group_trigger:
        System.get_env("ZAIK_TELEGRAM_GROUP_TRIGGER") ||
          Keyword.get(app_config, :group_trigger, "zaik")
    }
  end

  defp request(:get, url) do
    ensure_http_started()

    case :httpc.request(:get, {to_charlist(url), []}, [], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, body}} -> decode_response(status, body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(:post, url, payload) do
    ensure_http_started()
    body = Jason.encode!(payload)
    headers = [{~c"content-type", ~c"application/json"}]

    case :httpc.request(:post, {to_charlist(url), headers, ~c"application/json", body}, [],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, body}} -> decode_response(status, body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_response(status, body) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, %{"ok" => true, "result" => result}} -> {:ok, result}
      {:ok, decoded} -> {:error, {:telegram_api_error, decoded}}
      {:error, _} -> {:error, {:invalid_json, body}}
    end
  end

  defp decode_response(status, body) do
    decoded =
      case Jason.decode(body) do
        {:ok, value} -> value
        {:error, _} -> body
      end

    {:error, {:http_error, status, decoded}}
  end

  defp bot_url(token, path) do
    config().api_url |> String.trim_trailing("/") |> Kernel.<>("/bot#{token}#{path}")
  end

  defp ensure_http_started do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
  end

  defp require_value(nil, key), do: {:error, {:missing_config, key}}
  defp require_value("", key), do: {:error, {:missing_config, key}}
  defp require_value(value, _key), do: {:ok, value}

  defp env_bool(name, fallback) do
    case System.get_env(name) do
      nil -> fallback
      value -> value |> String.downcase() |> then(&(&1 in ["1", "true", "yes", "on"]))
    end
  end

  defp env_integer(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> nil
        end
    end
  end

  defp env_list(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
    end
  end
end

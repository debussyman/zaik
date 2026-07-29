defmodule Zaik.Messaging.SignalClient do
  @moduledoc """
  Minimal client for `signal-cli-rest-api`.

  This uses Erlang's built-in `:httpc` to avoid introducing a dependency before
  the integration is exercised locally.
  """

  @default_api_url "http://localhost:8080"

  def receive(account \\ configured_account()) do
    with {:ok, account} <- require_value(account, :account),
         {:ok, api_url} <- require_value(configured_api_url(), :api_url) do
      url = join_url(api_url, "/v1/receive/#{URI.encode_www_form(account)}")
      request(:get, url)
    end
  end

  def send_message(to, message, account \\ configured_account()) do
    with {:ok, account} <- require_value(account, :account),
         {:ok, api_url} <- require_value(configured_api_url(), :api_url) do
      payload = %{
        message: message,
        number: account,
        recipients: [to]
      }

      request(:post, join_url(api_url, "/v2/send"), payload)
    end
  end

  def config do
    app_config = Application.get_env(:zaik, :signal, [])

    %{
      enabled: env_bool("ZAIK_SIGNAL_ENABLED", Keyword.get(app_config, :enabled, false)),
      api_url:
        System.get_env("ZAIK_SIGNAL_API_URL") ||
          Keyword.get(app_config, :api_url, @default_api_url),
      account: System.get_env("ZAIK_SIGNAL_ACCOUNT") || Keyword.get(app_config, :account),
      allowed_senders:
        env_list("ZAIK_SIGNAL_ALLOWED_SENDERS") || Keyword.get(app_config, :allowed_senders, []),
      poll_interval_ms:
        env_integer("ZAIK_SIGNAL_POLL_INTERVAL_MS") ||
          Keyword.get(app_config, :poll_interval_ms, 5_000)
    }
  end

  def configured_account, do: config().account
  def configured_api_url, do: config().api_url

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
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, body}
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

  defp ensure_http_started do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
  end

  defp join_url(base, path) do
    String.trim_trailing(base, "/") <> path
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

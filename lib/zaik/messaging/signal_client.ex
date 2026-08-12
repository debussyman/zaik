defmodule Zaik.Messaging.SignalClient do
  @moduledoc """
  Minimal Signal client.

  Supports two backends:

  - `:cli` via native `signal-cli` from the dev shell
  - `:rest` via `signal-cli-rest-api`

  The CLI backend is the default because it avoids Docker/Podman and keeps the
  first live integration local and free.
  """

  @default_api_url "http://localhost:8080"
  @default_cli_path "signal-cli"

  def receive(account \\ configured_account()) do
    case config().mode do
      :cli -> receive_cli(account)
      :rest -> receive_rest(account)
    end
  end

  def send_message(to, message, account \\ configured_account()) do
    case config().mode do
      :cli -> send_message_cli(to, message, account)
      :rest -> send_message_rest(to, message, account)
    end
  end

  def list_accounts do
    case config().mode do
      :cli ->
        with {:ok, output} <- run_cli(["listAccounts"]) do
          {:ok, output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)}
        end

      :rest ->
        {:error, :unsupported_for_rest_client}
    end
  end

  def config do
    app_config = Application.get_env(:zaik, :signal, [])

    %{
      enabled: env_bool("ZAIK_SIGNAL_ENABLED", Keyword.get(app_config, :enabled, false)),
      mode: env_mode("ZAIK_SIGNAL_MODE", Keyword.get(app_config, :mode, :cli)),
      api_url:
        System.get_env("ZAIK_SIGNAL_API_URL") ||
          Keyword.get(app_config, :api_url, @default_api_url),
      account: System.get_env("ZAIK_SIGNAL_ACCOUNT") || Keyword.get(app_config, :account),
      allowed_senders:
        env_list("ZAIK_SIGNAL_ALLOWED_SENDERS") || Keyword.get(app_config, :allowed_senders, []),
      poll_interval_ms:
        env_integer("ZAIK_SIGNAL_POLL_INTERVAL_MS") ||
          Keyword.get(app_config, :poll_interval_ms, 5_000),
      cli_path:
        System.get_env("ZAIK_SIGNAL_CLI_PATH") ||
          Keyword.get(app_config, :cli_path, @default_cli_path),
      data_dir: System.get_env("ZAIK_SIGNAL_DATA_DIR") || Keyword.get(app_config, :data_dir)
    }
  end

  def configured_account, do: config().account
  def configured_api_url, do: config().api_url

  def decode_cli_json_output(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, decoded} when is_list(decoded) -> decoded
        {:ok, decoded} -> [decoded]
        {:error, _} -> []
      end
    end)
  end

  defp receive_cli(account) do
    with {:ok, _account} <- require_value(account, :account),
         {:ok, output} <-
           run_cli(
             global_cli_args(account) ++ ["receive", "--timeout", "1", "--max-messages", "20"]
           ) do
      {:ok, decode_cli_json_output(output)}
    end
  end

  defp send_message_cli(to, message, account) do
    with {:ok, account} <- require_value(account, :account),
         {:ok, _to} <- require_value(to, :recipient),
         {:ok, output} <- run_cli(global_cli_args(account) ++ send_cli_args(account, to, message)) do
      decoded = decode_cli_json_output(output)
      {:ok, if(decoded == [], do: output, else: decoded)}
    end
  end

  defp send_cli_args(account, account, message),
    do: ["send", "--note-to-self", "--message", message]

  defp send_cli_args(_account, to, message), do: ["send", "--message", message, to]

  defp run_cli(args, opts \\ []) do
    cli_path = config().cli_path
    cmd_opts = [stderr_to_stdout: true] ++ opts

    case System.cmd(cli_path, args, cmd_opts) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:signal_cli_failed, status, String.trim(output)}}
    end
  rescue
    error in ErlangError -> {:error, {:signal_cli_exec_failed, error.original}}
  end

  defp global_cli_args(account) do
    base = ["-o", "json", "-a", account]

    case config().data_dir do
      nil -> base
      "" -> base
      data_dir -> ["-d", data_dir | base]
    end
  end

  defp receive_rest(account) do
    with {:ok, account} <- require_value(account, :account),
         {:ok, api_url} <- require_value(configured_api_url(), :api_url) do
      url = join_url(api_url, "/v1/receive/#{URI.encode_www_form(account)}")
      request(:get, url)
    end
  end

  defp send_message_rest(to, message, account) do
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

  defp env_mode(name, fallback) do
    value = System.get_env(name) || to_string(fallback)

    case String.downcase(value) do
      "cli" -> :cli
      "rest" -> :rest
      _ -> :cli
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

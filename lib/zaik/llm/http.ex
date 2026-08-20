defmodule Zaik.LLM.HTTP do
  @moduledoc false

  def post_json(base_url, path, payload, timeout) do
    ensure_http_started()

    url = base_url |> String.trim_trailing("/") |> Kernel.<>(path)
    body = Jason.encode!(payload)
    headers = [{~c"content-type", ~c"application/json"}]

    case :httpc.request(
           :post,
           {to_charlist(url), headers, ~c"application/json", body},
           [timeout: timeout],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        decode_response(status, response_body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_response(status, body) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
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

  defp ensure_http_started do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
  end
end

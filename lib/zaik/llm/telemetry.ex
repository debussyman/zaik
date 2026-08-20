defmodule Zaik.LLM.Telemetry do
  @moduledoc false

  def record_call(kind, requested_model, result, started, opts) do
    duration_ms = System.monotonic_time(:millisecond) - started
    purpose = Keyword.get(opts, :purpose, kind)

    attrs =
      case result do
        {:ok, response} ->
          %{
            purpose: to_string(purpose),
            model: response.model || requested_model,
            success: true,
            duration_ms: duration_ms,
            response_length: String.length(response.response || ""),
            raw: response.raw,
            metadata: %{kind: kind}
          }

        {:error, reason} ->
          %{
            purpose: to_string(purpose),
            model: requested_model,
            success: false,
            duration_ms: duration_ms,
            error: inspect(reason),
            metadata: %{kind: kind}
          }
      end

    Zaik.TelemetryStore.safe_record_llm_call(attrs)
  end
end

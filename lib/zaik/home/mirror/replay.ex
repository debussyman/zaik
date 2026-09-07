defmodule Zaik.Home.Mirror.Replay do
  @moduledoc """
  Converts privacy-filtered production outcomes into durable mirror scenarios.

  A replay always starts from an explicit scenario template because chat traces
  are not canonical state. Raw sender/chat identifiers and message contents are
  rejected; callers must provide replacements before the trace can be attached.
  """

  alias Zaik.Home.Mirror.Scenario

  @private_keys ~w(sender sender_id chat_id session_id prompt content context context_json)

  def from_trace(%Scenario{} = template, trace, opts \\ []) when is_map(trace) do
    replacements = Keyword.get(opts, :replacements, %{})
    sanitized = sanitize(trace, replacements)

    with :ok <- privacy_check(sanitized) do
      metadata =
        template.metadata
        |> Map.put(:replay_source_fingerprint, fingerprint(sanitized))
        |> Map.put(
          :replay_failure_labels,
          Zaik.Learning.FailureLabels.classify(trace_result(trace), trace_calls(trace))
        )
        |> Map.put(:replay_trace, sanitized)
        |> Map.put(:tool_fingerprint, Zaik.Tools.Registry.fingerprint())
        |> Map.put(:capability_fingerprint, Zaik.Home.Capabilities.Registry.fingerprint())

      Scenario.new(%{Map.from_struct(template) | metadata: metadata})
    end
  end

  def capability_change(%Scenario{} = template, previous_fingerprint) do
    metadata =
      template.metadata
      |> Map.put(:capability_change_from, previous_fingerprint)
      |> Map.put(:capability_fingerprint, Zaik.Home.Capabilities.Registry.fingerprint())
      |> Map.put(:tool_fingerprint, Zaik.Tools.Registry.fingerprint())

    Scenario.new(%{Map.from_struct(template) | metadata: metadata})
  end

  def sanitize(value, replacements \\ %{}) do
    replacements = Map.new(replacements, fn {from, to} -> {to_string(from), to_string(to)} end)
    do_sanitize(value, replacements)
  end

  def privacy_check(value) do
    case find_private_key(value) do
      nil -> :ok
      key -> {:error, {:unsanitized_private_field, key}}
    end
  end

  def fingerprint(value) do
    value
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp do_sanitize(value, replacements) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> to_string(key) in @private_keys end)
    |> Map.new(fn {key, nested} -> {key, do_sanitize(nested, replacements)} end)
  end

  defp do_sanitize(value, replacements) when is_list(value),
    do: Enum.map(value, &do_sanitize(&1, replacements))

  defp do_sanitize(value, replacements) when is_binary(value) do
    Enum.reduce(replacements, value, fn {from, to}, acc -> String.replace(acc, from, to) end)
  end

  defp do_sanitize(value, _replacements), do: value

  defp find_private_key(value) when is_map(value) do
    Enum.find_value(value, fn {key, nested} ->
      if to_string(key) in @private_keys, do: to_string(key), else: find_private_key(nested)
    end)
  end

  defp find_private_key(value) when is_list(value),
    do: Enum.find_value(value, &find_private_key/1)

  defp find_private_key(_value), do: nil

  defp trace_result(trace),
    do: Map.get(trace, :result) || Map.get(trace, "result") || {:ok, :unknown}

  defp trace_calls(trace),
    do: Map.get(trace, :tool_calls) || Map.get(trace, "tool_calls") || []

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end

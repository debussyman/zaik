defmodule Zaik.Home.GoalCandidate do
  @moduledoc """
  Typed desired-state candidate emitted by a home policy.

  Candidates are inert data. They cannot execute tools or adapter commands.
  """

  @enforce_keys [
    :id,
    :policy_id,
    :policy_version,
    :scope,
    :priority,
    :confidence,
    :desired_state,
    :evidence,
    :reason,
    :created_at,
    :expires_at,
    :fingerprint
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          policy_id: String.t(),
          policy_version: String.t(),
          scope: String.t(),
          priority: non_neg_integer(),
          confidence: float(),
          desired_state: [map()],
          evidence: map(),
          reason: String.t(),
          created_at: String.t(),
          expires_at: String.t(),
          fingerprint: String.t()
        }

  def new(attrs, opts \\ [])

  def new(attrs, opts) when is_map(attrs) do
    capability_opts = Keyword.get(opts, :capability_opts, [])

    with {:ok, policy_id} <- required_string(attrs, :policy_id),
         {:ok, policy_version} <- required_string(attrs, :policy_version),
         {:ok, scope} <- required_string(attrs, :scope),
         {:ok, reason} <- required_string(attrs, :reason),
         {:ok, priority} <- priority(value(attrs, :priority)),
         {:ok, confidence} <- confidence(value(attrs, :confidence)),
         {:ok, desired_state} <- desired_state(value(attrs, :desired_state), capability_opts),
         evidence when is_map(evidence) <- value(attrs, :evidence),
         {:ok, created_at} <- datetime(value(attrs, :created_at), :invalid_created_at),
         {:ok, expires_at} <- datetime(value(attrs, :expires_at), :invalid_expires_at),
         :ok <- expiry_order(created_at, expires_at) do
      canonical = %{
        policy_id: policy_id,
        policy_version: policy_version,
        scope: scope,
        priority: priority,
        confidence: confidence,
        desired_state: desired_state,
        evidence: evidence,
        reason: reason,
        created_at: DateTime.to_iso8601(created_at),
        expires_at: DateTime.to_iso8601(expires_at)
      }

      fingerprint = fingerprint(canonical)

      {:ok,
       struct!(
         __MODULE__,
         Map.merge(canonical, %{
           id: value(attrs, :id) || "goal_" <> String.slice(fingerprint, 0, 24),
           fingerprint: fingerprint
         })
       )}
    else
      nil -> {:error, :missing_evidence}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_evidence}
    end
  end

  def new(_attrs, _opts), do: {:error, :invalid_candidate}

  def new!(attrs, opts \\ []) do
    case new(attrs, opts) do
      {:ok, candidate} -> candidate
      {:error, reason} -> raise ArgumentError, "invalid home goal candidate: #{inspect(reason)}"
    end
  end

  defp desired_state(actions, capability_opts) when is_list(actions) and actions != [] do
    actions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {action, index}, {:ok, acc} ->
      case desired_action(action, capability_opts) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_desired_state, index, reason}}}
      end
    end)
  end

  defp desired_state(_actions, _opts), do: {:error, :empty_desired_state}

  defp desired_action(action, capability_opts) when is_map(action) do
    with {:ok, entity_id} <- required_string(action, :entity_id),
         {:ok, device} <- required_string(action, :device),
         {:ok, capability} <- required_string(action, :capability),
         target when is_map(target) <- value(action, :target),
         {:ok, module} <- Zaik.Home.Capabilities.Registry.fetch(capability, capability_opts),
         {:ok, target} <- module.validate_target(target) do
      {:ok,
       %{
         entity_id: entity_id,
         device: device,
         capability: capability,
         target: target
       }}
    else
      nil -> {:error, :missing_target}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_target}
    end
  end

  defp desired_action(_action, _opts), do: {:error, :invalid_action}

  defp priority(value) when is_integer(value) and value in 0..100, do: {:ok, value}
  defp priority(_value), do: {:error, :invalid_priority}

  defp confidence(value) when is_number(value) and value >= 0 and value <= 1,
    do: {:ok, Float.round(value / 1, 3)}

  defp confidence(_value), do: {:error, :invalid_confidence}

  defp required_string(map, key) do
    case value(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, {:missing, key}}, else: {:ok, value}

      _ ->
        {:error, {:missing, key}}
    end
  end

  defp datetime(%DateTime{} = value, _error), do: {:ok, value}

  defp datetime(value, error) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, error}
    end
  end

  defp datetime(_value, error), do: {:error, error}

  defp expiry_order(created_at, expires_at) do
    if DateTime.after?(expires_at, created_at), do: :ok, else: {:error, :invalid_expiry}
  end

  defp fingerprint(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

defmodule Zaik.Home.Capabilities.Contract do
  @moduledoc """
  Executable baseline contract required for runtime capability modules.

  The baseline protects composability: a capability must have a complete typed
  descriptor and must not claim or project an unrelated payload.
  """

  def validate(module) when is_atom(module) do
    with :ok <- exports_contract(module),
         {:ok, descriptor} <- descriptor(module),
         :ok <- unrelated_payload_is_ignored(module),
         :ok <- target_semantics(module, descriptor) do
      :ok
    end
  rescue
    error -> {:error, {:capability_contract_exception, module, error}}
  catch
    kind, reason -> {:error, {:capability_contract_throw, module, kind, reason}}
  end

  defp exports_contract(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :descriptor, 0) and
         function_exported?(module, :detected?, 1) and function_exported?(module, :state, 1) and
         function_exported?(module, :validate_target, 1) do
      :ok
    else
      {:error, {:missing_capability_callbacks, module}}
    end
  end

  defp descriptor(module) do
    case module.descriptor() do
      %{
        id: id,
        description: description,
        state_schema: state_schema,
        target_schema: target_schema
      }
      when is_binary(id) and id != "" and is_binary(description) and description != "" and
             is_map(state_schema) and (is_map(target_schema) or is_nil(target_schema)) ->
        {:ok, module.descriptor()}

      descriptor ->
        {:error, {:invalid_capability_descriptor, module, descriptor}}
    end
  end

  defp unrelated_payload_is_ignored(module) do
    unrelated = %{payload: %{"zaik_unrelated_probe" => 1}, metadata: %{}}

    if module.detected?(unrelated) == false do
      :ok
    else
      {:error, {:capability_claims_unrelated_payload, module}}
    end
  end

  defp target_semantics(module, %{target_schema: nil}) do
    case module.validate_target(%{}) do
      {:error, :read_only_capability} -> :ok
      other -> {:error, {:read_only_capability_accepts_target, module, other}}
    end
  end

  defp target_semantics(module, %{target_schema: target_schema}) when is_map(target_schema) do
    case module.validate_target(%{"zaik_invalid_target_probe" => true}) do
      {:error, _reason} -> :ok
      other -> {:error, {:capability_accepts_unrelated_target, module, other}}
    end
  end
end

defmodule Zaik.Home.Tools.GetActionStatus do
  @moduledoc """
  Read-only lookup for runtime or persisted home-action status.
  """

  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "get_home_action_status",
      aliases: ["home_action_status", "get_action_status"],
      description:
        "Read verification and persisted execution status for an existing home action ID.",
      kind: :read,
      risk: :none,
      input_schema: %{
        "type" => "object",
        "required" => ["action_id"],
        "properties" => %{"action_id" => %{"type" => "string"}}
      }
    }
  end

  @impl true
  def run(args, context) do
    action_id = value(args, :action_id)
    verifier = setting(context, :action_verifier, Zaik.Home.ActionVerifier)
    ledger = setting(context, :action_ledger, Zaik.Home.ActionLedger)

    with {:ok, action_id} <- non_empty(action_id) do
      case verifier_status(verifier, action_id) do
        {:ok, status} -> {:ok, %{source: "verifier", action_id: action_id, status: status}}
        {:error, :not_found} -> ledger_status(ledger, action_id)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp verifier_status(verifier, action_id) do
    Zaik.Home.ActionVerifier.status(action_id, server: verifier)
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp ledger_status(ledger, action_id) do
    case Zaik.Home.ActionLedger.lookup(action_id, ledger) do
      {:ok, entry} -> {:ok, %{source: "ledger", action_id: action_id, status: entry}}
      error -> error
    end
  catch
    :exit, reason -> {:error, {:status_store_unavailable, reason}}
  end

  defp non_empty(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_action_id}
      value -> {:ok, value}
    end
  end

  defp non_empty(_value), do: {:error, :invalid_action_id}

  defp setting(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key), default)
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

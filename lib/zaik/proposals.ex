defmodule Zaik.Proposals do
  @moduledoc """
  Human-confirmed proposal workflow for modifications Zaik should not apply on its own.

  Automated jobs can create proposals. Chat/UI surfaces can list, inspect, approve,
  or reject them. Execution of an approved action is intentionally separate so future
  write/control paths can remain explicit and supervised.
  """

  @type proposal :: %{
          id: binary(),
          status: binary(),
          type: binary(),
          title: binary(),
          body: binary(),
          action: map(),
          metadata: map(),
          created_by: binary() | nil,
          decided_by: binary() | nil,
          created_at: DateTime.t() | binary(),
          decided_at: DateTime.t() | binary() | nil
        }

  @doc "Create a pending proposal."
  def create(attrs) when is_map(attrs), do: Zaik.TelemetryStore.create_proposal(attrs)

  @doc "List proposals, pending by default."
  def list(status \\ :pending), do: Zaik.TelemetryStore.list_proposals(status)

  @doc "Fetch one proposal by ID."
  def get(id) when is_binary(id), do: Zaik.TelemetryStore.get_proposal(id)

  @doc "Approve a pending proposal. This does not execute the proposed action."
  def approve(id, decided_by \\ nil) when is_binary(id),
    do: Zaik.TelemetryStore.decide_proposal(id, :approved, decided_by)

  @doc "Reject a pending proposal."
  def reject(id, decided_by \\ nil) when is_binary(id),
    do: Zaik.TelemetryStore.decide_proposal(id, :rejected, decided_by)
end

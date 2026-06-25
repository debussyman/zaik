defmodule Zaik.Task do
  @moduledoc """
  A unit of work submitted to the Zaik harness.
  """

  @type status :: :queued | :assigned | :running | :succeeded | :failed | :cancelled | :timed_out

  @type t :: %__MODULE__{
          id: String.t(),
          type: atom(),
          payload: term(),
          priority: integer(),
          status: status(),
          session_id: String.t() | nil,
          parent_entry_id: String.t() | nil,
          context_entry_id: String.t() | nil,
          agent_module: module() | nil,
          agent_pid: pid() | nil,
          result: term(),
          error: term(),
          submitted_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          timeout_ms: pos_integer(),
          max_retries: non_neg_integer(),
          attempts: non_neg_integer(),
          metadata: map()
        }

  defstruct [
    :id,
    :type,
    :payload,
    :priority,
    :status,
    :session_id,
    :parent_entry_id,
    :context_entry_id,
    :agent_module,
    :agent_pid,
    :result,
    :error,
    :submitted_at,
    :started_at,
    :completed_at,
    timeout_ms: 60_000,
    max_retries: 0,
    attempts: 0,
    metadata: %{}
  ]

  @terminal_statuses [:succeeded, :failed, :cancelled, :timed_out]

  def new(type, payload, opts \\ []) when is_atom(type) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: Keyword.get_lazy(opts, :id, &new_id/0),
      type: type,
      payload: payload,
      priority: Keyword.get(opts, :priority, 50),
      status: :queued,
      session_id: Keyword.get(opts, :session_id),
      parent_entry_id: Keyword.get(opts, :parent_entry_id),
      context_entry_id: Keyword.get(opts, :context_entry_id),
      timeout_ms: Keyword.get(opts, :timeout_ms, 60_000),
      max_retries: Keyword.get(opts, :max_retries, 0),
      metadata: Keyword.get(opts, :metadata, %{}),
      submitted_at: now
    }
  end

  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses

  def mark_queued(%__MODULE__{} = task), do: %{task | status: :queued, agent_pid: nil}

  def mark_assigned(%__MODULE__{} = task, agent_module) do
    %{task | status: :assigned, agent_module: agent_module}
  end

  def mark_running(%__MODULE__{} = task, agent_pid) when is_pid(agent_pid) do
    %{
      task
      | status: :running,
        agent_pid: agent_pid,
        started_at: task.started_at || DateTime.utc_now()
    }
  end

  def mark_succeeded(%__MODULE__{} = task, result) do
    %{task | status: :succeeded, result: result, error: nil, completed_at: DateTime.utc_now()}
  end

  def mark_failed(%__MODULE__{} = task, reason) do
    %{task | status: :failed, error: reason, completed_at: DateTime.utc_now()}
  end

  def mark_cancelled(%__MODULE__{} = task) do
    %{task | status: :cancelled, completed_at: DateTime.utc_now()}
  end

  def mark_timed_out(%__MODULE__{} = task) do
    %{task | status: :timed_out, error: :timeout, completed_at: DateTime.utc_now()}
  end

  def increment_attempts(%__MODULE__{} = task), do: %{task | attempts: task.attempts + 1}

  defp new_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end

defmodule Zaik.MemoryStore do
  @moduledoc """
  Convenience API for appending and reading filesystem-backed session memory entries.
  """

  def append_message(session_id, role, content, opts \\ []) do
    Zaik.SessionStore.append(session_id, %{
      type: "message",
      role: to_string(role),
      content: content,
      exclude_from_context: Keyword.get(opts, :exclude_from_context, false),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  def append_task(%Zaik.Task{} = task, session_id), do: append_task(session_id, task)

  def append_task(session_id, %Zaik.Task{} = task) do
    Zaik.SessionStore.append(session_id, %{
      type: "task",
      taskId: task.id,
      taskType: to_string(task.type),
      payload: task.payload,
      priority: task.priority,
      metadata: task.metadata
    })
  end

  def append_task_result(session_id, %Zaik.Task{} = task, result) do
    Zaik.SessionStore.append(session_id, %{
      type: "task_result",
      taskId: task.id,
      taskType: to_string(task.type),
      status: to_string(task.status),
      result: result
    })
  end

  def append_summary(session_id, summary, opts \\ []) do
    Zaik.SessionStore.append(session_id, %{
      type: "summary",
      summary: summary,
      firstKeptEntryId: Keyword.get(opts, :first_kept_entry_id),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  def recent(session_id, limit \\ 20) do
    with {:ok, entries} <- Zaik.SessionStore.get_branch(session_id) do
      {:ok, entries |> Enum.reject(&excluded_from_context?/1) |> Enum.take(-limit)}
    end
  end

  def branch(session_id), do: branch(session_id, :current)

  def branch(session_id, :current), do: Zaik.SessionStore.get_branch(session_id)

  def branch(session_id, leaf_id),
    do: Zaik.SessionStore.get_branch(Zaik.SessionStore, session_id, leaf_id)

  defp excluded_from_context?(%{"exclude_from_context" => true}), do: true
  defp excluded_from_context?(_entry), do: false
end

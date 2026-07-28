defmodule Zaik.ContextBuilder do
  @moduledoc """
  Builds task/session context from filesystem-backed session memory.
  """

  def build(%Zaik.Task{session_id: nil}), do: {:ok, []}
  def build(%Zaik.Task{session_id: session_id}), do: build(session_id, [])

  def build(session_id, opts) when is_binary(session_id) do
    limit = Keyword.get(opts, :limit, 50)

    with {:ok, entries} <- Zaik.SessionStore.get_branch(session_id) do
      context =
        entries
        |> Enum.reject(&excluded_from_context?/1)
        |> apply_summary_window()
        |> Enum.take(-limit)

      {:ok, context}
    end
  end

  defp excluded_from_context?(%{"exclude_from_context" => true}), do: true
  defp excluded_from_context?(_entry), do: false

  defp apply_summary_window(entries) do
    case latest_summary_index(entries) do
      nil -> entries
      index -> Enum.drop(entries, index)
    end
  end

  defp latest_summary_index(entries) do
    entries
    |> Enum.with_index()
    |> Enum.filter(fn {entry, _index} -> entry["type"] == "summary" end)
    |> List.last()
    |> case do
      nil -> nil
      {_entry, index} -> index
    end
  end
end

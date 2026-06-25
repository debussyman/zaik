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
        |> Enum.reject(&(&1["exclude_from_context"] == true))
        |> apply_summary_window()
        |> Enum.take(-limit)

      {:ok, context}
    end
  end

  defp apply_summary_window(entries) do
    case Enum.find_index(Enum.reverse(entries), &(&1["type"] == "summary")) do
      nil ->
        entries

      reverse_index ->
        index = length(entries) - reverse_index - 1
        {before_and_summary, after_summary} = Enum.split(entries, index + 1)
        [List.last(before_and_summary) | after_summary]
    end
  end
end

defmodule Zaik.Analytics.OperationalAnswers do
  @moduledoc """
  Deterministic SQL-backed answers for common Zaik operational-memory questions.

  This sits before the freeform agent loop so frequently asked observability
  questions are reliable even if the tool-planning model emits invalid JSON.
  """

  def answer(text) when is_binary(text) do
    normalized = text |> String.downcase() |> String.trim()

    cond do
      asked_today?(normalized) -> asked_today()
      recent_failures?(normalized) -> recent_failures()
      true -> :unknown
    end
  end

  def answer(_text), do: :unknown

  defp asked_today?(text) do
    String.contains?(text, "ask") and
      (String.contains?(text, "today") or String.contains?(text, "recent")) and
      (String.contains?(text, "you") or String.contains?(text, "zaik") or
         String.contains?(text, "we"))
  end

  defp recent_failures?(text) do
    String.contains?(text, "fail") and
      (String.contains?(text, "task") or String.contains?(text, "zaik") or
         String.contains?(text, "recent") or String.contains?(text, "today"))
  end

  defp asked_today do
    today = Date.utc_today() |> Date.to_iso8601()

    case Zaik.TelemetryStore.query(
           """
           SELECT created_at, channel, sender_id, chat_id, content
           FROM zaik_messages
           WHERE role = 'user'
             AND substr(created_at, 1, 10) = ?
           ORDER BY created_at ASC
           LIMIT 20
           """,
           [today]
         ) do
      {:ok, %{rows: []}} ->
        {:ok, "I don't have any recorded user messages from today yet."}

      {:ok, %{rows: rows}} ->
        lines =
          rows
          |> Enum.map(fn row ->
            time = row["created_at"] |> format_time()
            channel = row["channel"] || "unknown"
            content = row["content"] || ""
            "- #{time} via #{channel}: #{content}"
          end)

        {:ok, Enum.join(["Here is what you've asked me today:" | lines], "\n")}

      {:error, reason} ->
        {:ok, "I couldn't read message history yet: #{inspect(reason)}"}
    end
  end

  defp recent_failures do
    case Zaik.TelemetryStore.query(
           """
           SELECT id, type, status, completed_at, error_json
           FROM zaik_tasks
           WHERE status IN ('failed', 'timed_out', 'cancelled')
           ORDER BY COALESCE(completed_at, updated_at) DESC
           LIMIT 10
           """,
           []
         ) do
      {:ok, %{rows: []}} ->
        {:ok, "I don't see any recent failed, timed out, or cancelled tasks."}

      {:ok, %{rows: rows}} ->
        lines =
          Enum.map(rows, fn row ->
            at = format_time(row["completed_at"])
            "- #{at} #{row["type"]} #{row["status"]}: #{row["error_json"] || "no error recorded"}"
          end)

        {:ok, Enum.join(["Recent task problems:" | lines], "\n")}

      {:error, reason} ->
        {:ok, "I couldn't read task history yet: #{inspect(reason)}"}
    end
  end

  defp format_time(nil), do: "unknown time"

  defp format_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> Calendar.strftime(datetime, "%H:%M")
      _ -> iso
    end
  end
end

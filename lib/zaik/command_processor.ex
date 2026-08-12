defmodule Zaik.CommandProcessor do
  @moduledoc """
  Safe text command processor for local and messaging-based control surfaces.
  """

  @brief_await_ms 2_000

  def process(text, context \\ %{})

  def process(text, context) when is_binary(text) do
    text = String.trim(text)

    cond do
      text == "" ->
        help()

      command?(text, "help") ->
        help()

      command?(text, "health") ->
        format_health()

      command?(text, "snapshot") ->
        inspect(Zaik.Observability.snapshot(), pretty: true, limit: 50)

      command?(text, "queue") ->
        format_queue()

      command?(text, "tasks") ->
        format_tasks(nil)

      command?(text, "sessions") ->
        format_sessions()

      command?(text, "system") ->
        submit_system(context)

      command?(text, "watchdog") ->
        format_watchdog_state()

      command?(text, "watchdog scan") ->
        format_watchdog_scan()

      command?(text, "ask") ->
        submit_llm_prompt("", context)

      command?(text, "submit llm") ->
        submit_llm_prompt("", context)

      String.starts_with?(downcase(text), "ask ") ->
        text |> rest_after("ask") |> submit_llm_prompt(context)

      String.starts_with?(downcase(text), "submit llm ") ->
        text |> rest_after("submit llm") |> submit_llm_prompt(context)

      String.starts_with?(downcase(text), "tasks ") ->
        text |> rest_after("tasks") |> format_tasks()

      String.starts_with?(downcase(text), "task ") ->
        text |> rest_after("task") |> format_task()

      String.starts_with?(downcase(text), "submit echo ") ->
        text |> rest_after("submit echo") |> submit_echo(context)

      String.starts_with?(downcase(text), "echo ") ->
        text |> rest_after("echo") |> submit_echo(context)

      command?(text, "submit system") ->
        submit_system(context)

      true ->
        "Unknown command.\n\n" <> help()
    end
  end

  def process(_text, _context), do: help()

  def help do
    """
    Zaik commands:
    help
    health
    snapshot
    queue
    tasks
    tasks queued|running|failed
    task <task_id>
    sessions
    watchdog
    watchdog scan
    ask <prompt>
    submit llm <prompt>
    submit echo <message>
    echo <message>
    system
    """
    |> String.trim()
  end

  defp format_health do
    snapshot = Zaik.Observability.snapshot()
    tasks = snapshot.tasks

    """
    Zaik is #{snapshot.status}.
    Queue: #{snapshot.queue.size}
    Running: #{tasks.running}
    Succeeded: #{tasks.succeeded}
    Failed: #{tasks.failed}
    Timed out: #{tasks.timed_out}
    """
    |> String.trim()
  end

  defp format_queue do
    queue = Zaik.Observability.queue_summary()
    "Queue: #{queue.size}"
  end

  defp format_tasks(nil) do
    tasks = Zaik.Observability.task_summary()

    """
    Tasks
    Queued: #{tasks.queued}
    Assigned: #{tasks.assigned}
    Running: #{tasks.running}
    Succeeded: #{tasks.succeeded}
    Failed: #{tasks.failed}
    Cancelled: #{tasks.cancelled}
    Timed out: #{tasks.timed_out}
    """
    |> String.trim()
  end

  defp format_tasks(status_text) when is_binary(status_text) do
    case parse_status(status_text) do
      {:ok, status} ->
        tasks = Zaik.list_tasks(status: status)

        case tasks do
          [] ->
            "No #{status} tasks."

          tasks ->
            lines =
              tasks
              |> Enum.take(-10)
              |> Enum.map(&format_task_line/1)

            (["#{String.capitalize(to_string(status))} tasks"] ++ lines) |> Enum.join("\n")
        end

      :error ->
        "Unknown task status: #{status_text}"
    end
  end

  defp format_task(task_id) do
    task_id = String.trim(task_id)

    case Zaik.get_task(task_id) do
      {:ok, task} ->
        """
        Task #{task.id}
        Type: #{task.type}
        Status: #{task.status}
        Attempts: #{task.attempts}/#{task.max_retries + 1}
        Submitted: #{format_time(task.submitted_at)}
        Started: #{format_time(task.started_at)}
        Completed: #{format_time(task.completed_at)}
        Result: #{format_value(task.result)}
        Error: #{format_value(task.error)}
        """
        |> String.trim()

      {:error, :not_found} ->
        "Task not found: #{task_id}"
    end
  end

  defp format_sessions do
    summary = Zaik.Observability.session_summary(limit: 10)

    case summary.recent do
      [] ->
        "No sessions."

      sessions ->
        lines =
          Enum.map(sessions, fn session ->
            "#{session.id} #{session.scope} #{session.cwd} updated=#{format_time(session.updated_at)}"
          end)

        (["Recent sessions"] ++ lines) |> Enum.join("\n")
    end
  end

  defp format_watchdog_state do
    case Zaik.watchdog_state() do
      %{last_scan_at: nil, last_summary: summary} ->
        "Watchdog has not scanned yet.\nLast summary: #{format_value(summary)}"

      %{last_scan_at: scanned_at, last_summary: summary} ->
        "Watchdog last scanned at #{format_time(scanned_at)}.\n" <>
          format_watchdog_summary(summary)
    end
  rescue
    _ -> "Watchdog is not available."
  catch
    :exit, _ -> "Watchdog is not available."
  end

  defp format_watchdog_scan do
    Zaik.watchdog_scan()
    |> format_watchdog_summary("Watchdog scan complete.")
  rescue
    error -> "Watchdog scan failed: #{Exception.message(error)}"
  catch
    :exit, reason -> "Watchdog scan failed: #{inspect(reason)}"
  end

  defp format_watchdog_summary(summary, header \\ "Watchdog summary.") when is_map(summary) do
    """
    #{header}
    Requeued missing queued: #{Map.get(summary, :requeued_missing_queued_tasks, 0)}
    Removed terminal queue entries: #{Map.get(summary, :removed_terminal_queue_entries, 0)}
    Removed missing queue entries: #{Map.get(summary, :removed_missing_queue_entries, 0)}
    Requeued stale assigned: #{Map.get(summary, :requeued_stale_assigned_tasks, 0)}
    Failed stale assigned: #{Map.get(summary, :failed_stale_assigned_tasks, 0)}
    Requeued orphaned running: #{Map.get(summary, :requeued_orphaned_running_tasks, 0)}
    Failed orphaned running: #{Map.get(summary, :failed_orphaned_running_tasks, 0)}
    Requeued stale running: #{Map.get(summary, :requeued_stale_running_tasks, 0)}
    Failed stale running: #{Map.get(summary, :failed_stale_running_tasks, 0)}
    Terminated terminal agents: #{Map.get(summary, :terminated_terminal_task_agents, 0)}
    """
    |> String.trim()
  end

  defp submit_echo(message, context) do
    message = String.trim(message)

    if message == "" do
      "Usage: submit echo <message>"
    else
      opts = task_opts(context)

      case Zaik.submit_task(:echo, %{message: message}, opts) do
        {:ok, task_id} ->
          case Zaik.await_task(task_id, @brief_await_ms) do
            {:ok, result} ->
              "Submitted echo task #{task_id}.\nResult: #{format_echo_result(result)}"

            {:error, :timeout} ->
              "Submitted echo task #{task_id}.\nTask is still running."

            {:error, reason} ->
              "Submitted echo task #{task_id}.\nTask failed: #{format_value(reason)}"
          end

        {:error, reason} ->
          "Failed to submit echo task: #{format_value(reason)}"
      end
    end
  end

  defp submit_llm_prompt(prompt, context) do
    prompt = String.trim(prompt)

    if prompt == "" do
      "Usage: ask <prompt>"
    else
      opts =
        context
        |> task_opts()
        |> Keyword.put_new(:timeout_ms, Zaik.LLM.OllamaClient.config().timeout_ms)

      payload = %{
        prompt: prompt,
        model: Zaik.LLM.OllamaClient.config().default_model,
        num_predict: Zaik.LLM.OllamaClient.config().num_predict,
        num_ctx: Zaik.LLM.OllamaClient.config().num_ctx,
        temperature: Zaik.LLM.OllamaClient.config().temperature
      }

      case Zaik.submit_task(:llm_prompt, payload, opts) do
        {:ok, task_id} ->
          case Zaik.await_task(task_id, Zaik.LLM.OllamaClient.config().timeout_ms + 5_000) do
            {:ok, result} ->
              "LLM task #{task_id}.\n" <> format_llm_result(result)

            {:error, :timeout} ->
              "LLM task #{task_id} is still running."

            {:error, reason} ->
              "LLM task #{task_id} failed: #{format_value(reason)}"
          end

        {:error, reason} ->
          "Failed to submit LLM task: #{format_value(reason)}"
      end
    end
  end

  defp submit_system(context) do
    opts = task_opts(context)

    case Zaik.submit_task(:system_status, %{detail: :basic}, opts) do
      {:ok, task_id} ->
        case Zaik.await_task(task_id, @brief_await_ms) do
          {:ok, result} ->
            "System status task #{task_id}.\n" <> format_system_result(result)

          {:error, :timeout} ->
            "System status task #{task_id} is still running."

          {:error, reason} ->
            "System status task #{task_id} failed: #{format_value(reason)}"
        end

      {:error, reason} ->
        "Failed to submit system status task: #{format_value(reason)}"
    end
  end

  defp task_opts(%{session_id: session_id}) when is_binary(session_id),
    do: [session_id: session_id]

  defp task_opts(_context), do: []

  defp parse_status(status_text) do
    case status_text |> String.trim() |> String.downcase() do
      "queued" -> {:ok, :queued}
      "assigned" -> {:ok, :assigned}
      "running" -> {:ok, :running}
      "succeeded" -> {:ok, :succeeded}
      "failed" -> {:ok, :failed}
      "cancelled" -> {:ok, :cancelled}
      "timed_out" -> {:ok, :timed_out}
      "timed out" -> {:ok, :timed_out}
      _ -> :error
    end
  end

  defp format_task_line(task) do
    "#{task.id} #{task.type} status=#{task.status} submitted=#{format_time(task.submitted_at)}"
  end

  defp format_echo_result(%{message: message}), do: message
  defp format_echo_result(%{"message" => message}), do: message
  defp format_echo_result(result), do: format_value(result)

  defp format_system_result(result) when is_map(result) do
    """
    Node: #{Map.get(result, :node) || Map.get(result, "node")}
    Uptime ms: #{Map.get(result, :uptime_ms) || Map.get(result, "uptime_ms")}
    Processes: #{Map.get(result, :process_count) || Map.get(result, "process_count")}
    Schedulers: #{Map.get(result, :schedulers_online) || Map.get(result, "schedulers_online")}
    """
    |> String.trim()
  end

  defp format_system_result(result), do: format_value(result)

  defp format_llm_result(%{response: response}) when is_binary(response),
    do: String.trim(response)

  defp format_llm_result(%{"response" => response}) when is_binary(response),
    do: String.trim(response)

  defp format_llm_result(result), do: format_value(result)

  defp format_value(nil), do: "-"
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value, limit: 20)

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp format_time(time), do: to_string(time)

  defp command?(text, command), do: downcase(text) == command
  defp downcase(text), do: text |> String.trim() |> String.downcase()

  defp rest_after(text, prefix) do
    text
    |> String.trim()
    |> String.slice(String.length(prefix)..-1//1)
    |> String.trim()
  end
end

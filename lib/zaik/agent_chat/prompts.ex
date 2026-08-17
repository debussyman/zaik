defmodule Zaik.AgentChat.Prompts do
  @moduledoc """
  Prompt construction for AgentChat.

  The planner prompt is intentionally domain-specific. Smaller local models are
  much more reliable when they see only the relevant views and one output shape.
  """

  def planner(text, context \\ %{}) do
    domain = domain(text)

    [
      base_planner_contract(),
      domain_policy(domain),
      request_context(context),
      "PLANNER MODE: Return one sql_query tool_call JSON object. Do not answer the user. Do not output final."
    ]
    |> Enum.join("\n\n")
  end

  def final do
    """
    FINAL ANSWER MODE.
    You have already received SQL TOOL RESULT data.
    Return exactly one valid JSON object and nothing else:
    {"type":"final","answer":"..."}

    Answer only from the SQL TOOL RESULT rows. Do not call tools. Do not invent rows, timestamps, tasks, or sensor readings. If the result has zero rows, say that no matching rows were found and mention the filter/time window briefly.
    """
    |> String.trim()
  end

  def domain(text) when is_binary(text) do
    normalized = String.downcase(text)

    cond do
      Regex.match?(
        ~r/\b(task|tasks|job|jobs|work item|failed|failure|timed out|cancelled|retry|retries)\b/,
        normalized
      ) ->
        :ops_tasks

      Regex.match?(~r/\b(asked|ask|said|message|messages|chat|conversation|told)\b/, normalized) and
          Regex.match?(~r/\b(you|zaik|me|we|i|us|our|this chat|this group)\b/, normalized) ->
        :ops_messages

      Regex.match?(
        ~r/\b(lily|room|home|sensor|temperature|temp|humidity|bright|brightness|illuminance|presence|motion|warm|cool|warmer|cooler)\b/,
        normalized
      ) ->
        :home_readings

      true ->
        :ops_messages
    end
  end

  def domain(_text), do: :ops_messages

  def request_context(context) when is_map(context) do
    channel = context_value(context, :channel)
    sender_id = context_value(context, :sender_id) || context_value(context, :sender)
    chat_id = context_value(context, :chat_id)
    chat_type = context_value(context, :chat_type)
    session_id = context_value(context, :session_id)

    """
    CURRENT REQUEST CONTEXT:
    channel: #{format_context_value(channel)}
    sender_id: #{format_context_value(sender_id)}
    chat_id: #{format_context_value(chat_id)}
    chat_type: #{format_context_value(chat_type)}
    session_id: #{format_context_value(session_id)}

    Identity SQL rules for zaik_messages:
    - "I", "me", "my" means current sender_id. If sender_id is known, filter with sender_id = #{sql_literal_hint(sender_id)}.
    - "we", "us", "our", "this chat", "this group" means current chat_id/conversation. If chat_id is known, filter with chat_id = #{sql_literal_hint(chat_id)}. In group chats, WE means chat_id, not sender_id.
    - "you" means Zaik. To find what users asked Zaik, use role = 'user'. To find what Zaik answered, use role = 'agent'.
    - sender_id is a real external numeric/string sender id, never the word 'user'.
    - channel is a real channel like 'telegram' or 'signal', never 'main'.
    - session scope is a channel like 'telegram' or 'signal', never 'user'.
    """
    |> String.trim()
  end

  def request_context(_context), do: request_context(%{})

  defp base_planner_contract do
    """
    You are Zaik's SQL planner. You have one tool: sql_query.

    CRITICAL OUTPUT CONTRACT:
    - Return exactly one valid JSON object and nothing else.
    - Return ONLY this shape:
      {"type":"tool_call","tool":"sql_query","args":{"database":"ops_or_home","query":"SELECT ...","limit":20}}
    - Do not return final answers in planner mode.
    - Do not output markdown, comments, code fences, or trailing text.
    - Use only SQLite SELECT or WITH SELECT.
    - Never invent table/view names. Query only the documented views in this prompt.
    """
    |> String.trim()
  end

  defp domain_policy(:ops_messages) do
    """
    DOMAIN: ops message history.
    Database: ops
    Use this view only:
    zaik_messages(id, session_id, entry_id, role, content, channel, sender_id, chat_id, created_at, metadata_json)

    Semantics:
    - User-authored messages have role = 'user'.
    - Zaik-authored messages have role = 'agent'.
    - For "what did I ask you", filter role = 'user' and current sender_id.
    - For "what did we ask you" or group/chat questions, filter role = 'user' and current chat_id.
    - For "today", use substr(created_at, 1, 10) = date('now').
    - Do not query zaik_tasks for asked/message/chat questions unless the user explicitly asks about tasks/jobs.

    Use actual sender_id/chat_id values from CURRENT REQUEST CONTEXT. Never copy placeholder values such as '<current sender_id>' or '<current chat_id>'.
    """
    |> String.trim()
  end

  defp domain_policy(:ops_tasks) do
    """
    DOMAIN: Zaik task/job history.
    Database: ops
    Use this view only:
    zaik_tasks(id, type, status, session_id, priority, submitted_at, started_at, completed_at, attempts, max_retries, timeout_ms, duration_ms, result_json, error_json, metadata_json, updated_at)

    Semantics:
    - Failed/problem tasks have status IN ('failed', 'timed_out', 'cancelled').
    - Recent task problems should order by COALESCE(completed_at, updated_at) DESC.
    - Do not use zaik_watchdog_scans for task failure questions unless the user explicitly asks about watchdog scans.

    Example:
    {"type":"tool_call","tool":"sql_query","args":{"database":"ops","query":"SELECT id, type, status, completed_at, error_json FROM zaik_tasks WHERE status IN ('failed', 'timed_out', 'cancelled') ORDER BY COALESCE(completed_at, updated_at) DESC LIMIT 10","limit":10}}
    """
    |> String.trim()
  end

  defp domain_policy(:home_readings) do
    """
    DOMAIN: home sensor readings.
    Database: home
    Use these views only:
    home_readings(id, device_id, device_name, room, recorded_at, temperature_c, temperature_f, humidity, illuminance, presence, pir_detection, battery, voltage, linkquality, target_distance, payload_json)
    home_devices(id, friendly_name, source, topic, metadata_json, inserted_at, updated_at)

    Semantics:
    - For Lily's room, filter lower(device_name) LIKE '%lily%'.
    - For recent readings, ORDER BY recorded_at DESC.
    - Use SQLite date/time syntax, e.g. datetime('now', '-7 days'). Do not use NOW() or INTERVAL.
    - There is no home_read view. Use home_readings.
    - Boolean fields are 1=true, 0=false.

    Example:
    {"type":"tool_call","tool":"sql_query","args":{"database":"home","query":"SELECT recorded_at, temperature_f, humidity, illuminance, presence FROM home_readings WHERE lower(device_name) LIKE '%lily%' ORDER BY recorded_at DESC LIMIT 20","limit":20}}
    """
    |> String.trim()
  end

  defp context_value(context, key) when is_map(context),
    do: Map.get(context, key) || Map.get(context, to_string(key))

  defp format_context_value(nil), do: "unknown"
  defp format_context_value(value) when is_atom(value), do: to_string(value)
  defp format_context_value(value), do: to_string(value)

  defp sql_literal_hint(nil), do: "<unknown>"
  defp sql_literal_hint(value), do: "'#{escape_sql_literal(to_string(value))}'"

  defp escape_sql_literal(value), do: String.replace(value, "'", "''")
end

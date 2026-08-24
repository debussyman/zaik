defmodule Zaik.AgentChat.Prompts do
  @moduledoc """
  Prompt construction for Zaik's house agent.

  Normal chat has one entrypoint/brain (`Zaik.AgentChat`). To keep local models
  reliable, the house agent uses compact internal working prompts for the part of
  house memory the current question needs. This is not a separate chat route: it
  is prompt scaffolding inside the single house agent.
  """

  def planner(text, context \\ %{}, forced_domain \\ nil) do
    domain = forced_domain || domain(text)

    [
      house_identity(domain),
      current_time_context(),
      domain_policy(domain),
      request_context(context),
      mode_instruction(domain)
    ]
    |> Enum.join("\n\n")
  end

  def final do
    """
    FINAL ANSWER MODE.
    You have already received SQL TOOL RESULT data.
    Return exactly one valid JSON object and nothing else:
    {"type":"final","answer":"..."}

    Answer only from the SQL TOOL RESULT rows. Do not call tools. Do not invent rows, timestamps, tasks, messages, or sensor readings. If the result has zero rows, say that no matching rows were found and mention the filter/time window briefly. Use a natural house-agent voice.
    """
    |> String.trim()
  end

  def system_prompt(context \\ %{}), do: planner("", context)

  def domain(text, opts \\ [])

  def domain(text, opts) when is_binary(text) do
    normalized = normalize_home_name(text)

    cond do
      Regex.match?(
        ~r/\b(agentchat|agent chat|fallback|fall back|fell back|primary model|fallback model|model used|which model|trace|tracing)\b/,
        normalized
      ) ->
        :agent_chat_runs

      Regex.match?(
        ~r/\b(task|tasks|job|jobs|work item|failed|failure|timed out|cancelled|retry|retries)\b/,
        normalized
      ) ->
        :ops_tasks

      Regex.match?(
        ~r/\b(asked|ask|question|questions|said|message|messages|chat|conversation|told)\b/,
        normalized
      ) and
          Regex.match?(~r/\b(you|zaik|me|we|i|us|our|this chat|this group)\b/, normalized) ->
        :ops_messages

      Regex.match?(
        ~r/\b(lily|room|bedroom|nursery|kitchen|bathroom|living room|office|basement|upstairs|downstairs|home|sensor|temperature|temp|humidity|bright|brightness|illuminance|presence|motion|warm|cool|warmer|cooler|change|changed|trend|trending)\b/,
        normalized
      ) ->
        :home_readings

      known_home_device_match?(normalized, opts) ->
        :home_readings

      true ->
        :general
    end
  end

  def domain(_text, _opts), do: :general

  defp known_home_device_match?(normalized_text, opts) do
    opts
    |> known_home_device_names()
    |> Enum.flat_map(&home_device_match_phrases/1)
    |> Enum.uniq()
    |> Enum.any?(&phrase_in_text?(normalized_text, &1))
  end

  defp known_home_device_names(opts) do
    Keyword.get(opts, :home_device_names) || runtime_home_device_names()
  end

  defp runtime_home_device_names do
    (device_store_names() ++ history_store_names())
    |> Enum.uniq()
  end

  defp device_store_names do
    if Process.whereis(Zaik.Home.DeviceStore) do
      Zaik.Home.DeviceStore.list_devices()
      |> Enum.map(&Map.get(&1, :friendly_name))
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  catch
    :exit, _reason -> []
  end

  defp history_store_names do
    if Process.whereis(Zaik.Home.HistoryStore) do
      Zaik.Home.HistoryStore.list_devices()
      |> Enum.map(&Map.get(&1, :friendly_name))
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  catch
    :exit, _reason -> []
  end

  defp home_device_match_phrases(name) when is_binary(name) do
    normalized_name = normalize_home_name(name)
    room_like = strip_device_words(normalized_name)

    [normalized_name, room_like]
    |> Enum.concat(significant_single_word_phrases(room_like))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp home_device_match_phrases(_name), do: []

  defp significant_single_word_phrases(room_like) do
    words = String.split(room_like, " ", trim: true)

    case words do
      [word] when byte_size(word) >= 4 -> [word]
      _ -> []
    end
  end

  defp strip_device_words(normalized_name) do
    normalized_name
    |> String.split(" ", trim: true)
    |> Enum.reject(
      &(&1 in [
          "sensor",
          "sensors",
          "multi",
          "multisensor",
          "fp300",
          "aqara",
          "presence",
          "motion",
          "climate",
          "temperature",
          "humidity",
          "device"
        ])
    )
    |> Enum.join(" ")
  end

  defp phrase_in_text?(_normalized_text, phrase) when byte_size(phrase) < 4, do: false

  defp phrase_in_text?(normalized_text, phrase) do
    Regex.match?(~r/(^|\s)#{Regex.escape(phrase)}(\s|$)/, normalized_text)
  end

  defp normalize_home_name(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp house_identity(:general) do
    """
    You are Zaik, a local personal house agent for this household.

    CRITICAL OUTPUT CONTRACT:
    - Return exactly one valid JSON object and nothing else.
    - Return ONLY this shape:
      {"type":"final","answer":"..."}
    - Answer ordinary conversational and general-knowledge questions directly.
    - Keep Zaik's identity: you are the house agent, not a disconnected chatbot.
    - For requests that would change the home or system state, do not execute anything; say changes require confirmation.
    - Do not output markdown, comments, code fences, or trailing text outside the JSON object.
    """
    |> String.trim()
  end

  defp house_identity(_domain) do
    """
    You are Zaik, a local personal house agent for this household.

    For this question you need Zaik/home/ops memory. Use the supervised read-only sql_query tool.

    CRITICAL OUTPUT CONTRACT:
    - Return exactly one valid JSON object and nothing else.
    - Before any SQL TOOL RESULT, return ONLY this shape:
      {"type":"tool_call","tool":"sql_query","args":{"database":"ops_or_home","query":"SELECT ...","limit":20}}
    - After one or more SQL TOOL RESULT messages, either answer from the gathered rows:
      {"type":"final","answer":"..."}
      or request one additional useful read-only SQL query if genuinely needed.
    - Do not claim you cannot access prior conversations, home history, task history, or model traces. Use SQL.
    - Do not output markdown, comments, code fences, or trailing text.
    - Use only SQLite SELECT or WITH SELECT.
    - Never invent table/view names. Query only the documented views in this prompt.
    """
    |> String.trim()
  end

  defp current_time_context do
    utc_now = DateTime.utc_now()
    local = local_datetime_tuple()

    """
    CURRENT TIME CONTEXT:
    utc_now: #{DateTime.to_iso8601(utc_now)}
    local_now: #{format_local_datetime(local)}
    local_utc_offset: #{format_local_offset(local, utc_now)}

    Use local_now to interpret human calendar language, and use UTC-compatible recorded_at/created_at filters when querying persisted history.
    """
    |> String.trim()
  end

  defp mode_instruction(:general) do
    "GENERAL CONVERSATION MODE: Return one final JSON object answering the user directly. Do not call tools."
  end

  defp mode_instruction(_domain) do
    "PLANNER MODE: Return one sql_query tool_call JSON object. Do not answer the user. Do not output final."
  end

  defp domain_policy(:general) do
    """
    DOMAIN: general conversation.

    Use general knowledge. Be concise, friendly, and useful. If the user asks about Zaik memory, home readings, tasks, failures, fallbacks, proposals, or other house data, the house agent should use a SQL working prompt instead of this direct-answer prompt.
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
    - For "what did I ask you" or "my questions", filter role = 'user' and current sender_id.
    - For "what did we ask you", "what have we asked you", "our questions", "this chat", or group/chat questions, filter role = 'user' and current chat_id.
    - NEVER use sender_id for "we", "us", "our", "this chat", or "this group" questions when chat_id is known.
    - For "today", use substr(created_at, 1, 10) = date('now').
    - For "recently", use ORDER BY created_at DESC LIMIT 10 or 20 unless the user gives a precise window.
    - Do not query zaik_tasks for asked/message/chat questions unless the user explicitly asks about tasks/jobs.

    Examples:
    User: what questions have we asked you recently?
    {"type":"tool_call","tool":"sql_query","args":{"database":"ops","query":"SELECT created_at, content FROM zaik_messages WHERE role = 'user' AND chat_id = '<current chat_id>' ORDER BY created_at DESC LIMIT 10","limit":10}}

    User: what have we asked you today?
    {"type":"tool_call","tool":"sql_query","args":{"database":"ops","query":"SELECT created_at, content FROM zaik_messages WHERE role = 'user' AND chat_id = '<current chat_id>' AND substr(created_at, 1, 10) = date('now') ORDER BY created_at DESC LIMIT 10","limit":10}}

    User: what have I asked you today?
    {"type":"tool_call","tool":"sql_query","args":{"database":"ops","query":"SELECT created_at, content FROM zaik_messages WHERE role = 'user' AND sender_id = '<current sender_id>' AND substr(created_at, 1, 10) = date('now') ORDER BY created_at DESC LIMIT 10","limit":10}}

    Replace placeholders with actual values from CURRENT REQUEST CONTEXT. Never output placeholders.
    """
    |> String.trim()
  end

  defp domain_policy(:agent_chat_runs) do
    """
    DOMAIN: AgentChat model/run tracing.
    Database: ops
    Use this view only:
    zaik_agent_chat_runs(id, prompt, context_json, channel, sender_id, chat_id, chat_type, session_id, primary_model, fallback_model, fallback_used, final_model, status, answer, error_json, tool_calls_json, duration_ms, metadata_json, created_at)

    Semantics:
    - fallback_used is 1 when the primary model failed or returned a low-confidence answer and the fallback model was tried.
    - channel, sender_id, chat_id, chat_type, and session_id come from the request context.
    - primary_model is the first model attempted.
    - fallback_model is the configured fallback model.
    - final_model is the model that produced the final public result.
    - status is 'ok' or 'error'.
    - Recent run questions should order by created_at DESC.
    - To inspect tool behavior, select tool_calls_json.

    Example:
    {"type":"tool_call","tool":"sql_query","args":{"database":"ops","query":"SELECT created_at, prompt, primary_model, fallback_used, final_model, status FROM zaik_agent_chat_runs ORDER BY created_at DESC LIMIT 10","limit":10}}
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
    DOMAIN: home sensor readings and trends.
    Database: home
    Use these views only:
    home_readings(id, device_id, device_name, room, recorded_at, temperature_c, temperature_f, humidity, illuminance, presence, pir_detection, battery, voltage, linkquality, target_distance, payload_json)
    home_devices(id, friendly_name, source, topic, metadata_json, inserted_at, updated_at)

    Semantics:
    - Device and room names are dynamic. Match the user's room/device words against lower(device_name), lower(room), and home_devices.friendly_name when needed.
    - For a named room/device like "main bedroom", filter lower(device_name) LIKE '%main bedroom%' OR lower(room) LIKE '%main bedroom%'.
    - If a named room/device has no matching home_readings rows, query home_devices with the same name words before saying there is no data.
    - For casual room-state questions like "what is it like in <room>" or "how is <room>", query the latest temperature_f, humidity, illuminance, presence, and linkquality for that room/device.
    - For recent readings, ORDER BY recorded_at DESC.
    - Prefer temperature_f for household-facing temperature answers.
    - Boolean fields are 1=true, 0=false.
    - Use SQLite date/time syntax, e.g. datetime('now', '-7 days'). Do not use NOW() or INTERVAL.
    - There is no home_read or home_reads view. Use home_readings.
    - Do not join to home_devices unless you need device metadata. home_readings already has device_name and room.

    Time windows:
    - Current local and UTC time are shown in CURRENT TIME CONTEXT.
    - Interpret natural-language time phrases using current local time.
    - For "today", use substr(recorded_at, 1, 10) = date('now') or equivalent UTC ISO bounds.
    - For "recently" without a precise window, use ORDER BY recorded_at DESC LIMIT 10 or 20.
    - For explicit relative durations such as "past/last 30 minutes", use recorded_at >= datetime('now', '-30 minutes').
    - For explicit relative durations such as "past/last 3 hours", use recorded_at >= datetime('now', '-3 hours').
    - For explicit relative durations such as "past/last N hours/minutes/days", translate N exactly into SQLite datetime('now', '-N unit').
    - For calendar phrases or parts of the day, infer the appropriate local calendar interval from current local time rather than copying a relative-duration example.
    - Do not collapse different requested time windows into one default trend window.

    For temperature/humidity/illuminance change over a window, compare the newest and oldest readings inside exactly that window.

    Examples:
    {"type":"tool_call","tool":"sql_query","args":{"database":"home","query":"SELECT recorded_at, temperature_f, humidity, illuminance, presence, linkquality FROM home_readings WHERE (lower(device_name) LIKE '%main bedroom%' OR lower(room) LIKE '%main bedroom%') ORDER BY recorded_at DESC LIMIT 20","limit":20}}
    {"type":"tool_call","tool":"sql_query","args":{"database":"home","query":"WITH windowed AS (SELECT recorded_at, temperature_f FROM home_readings WHERE (lower(device_name) LIKE '%nursery%' OR lower(room) LIKE '%nursery%') AND recorded_at >= datetime('now', '-30 minutes')), first_row AS (SELECT recorded_at, temperature_f FROM windowed ORDER BY recorded_at ASC LIMIT 1), last_row AS (SELECT recorded_at, temperature_f FROM windowed ORDER BY recorded_at DESC LIMIT 1) SELECT first_row.recorded_at AS first_recorded_at, first_row.temperature_f AS first_temperature_f, last_row.recorded_at AS last_recorded_at, last_row.temperature_f AS last_temperature_f, last_row.temperature_f - first_row.temperature_f AS temperature_change_f FROM first_row CROSS JOIN last_row","limit":1}}
    {"type":"tool_call","tool":"sql_query","args":{"database":"home","query":"SELECT friendly_name, updated_at, metadata_json FROM home_devices WHERE lower(friendly_name) LIKE '%main bedroom%' ORDER BY updated_at DESC LIMIT 10","limit":10}}
    """
    |> String.trim()
  end

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

    Identity SQL rules:
    - "I", "me", "my" means current sender_id. If sender_id is known, filter with sender_id = #{sql_literal_hint(sender_id)}.
    - "we", "us", "our", "this chat", "this group" means current chat_id/conversation. If chat_id is known, filter with chat_id = #{sql_literal_hint(chat_id)}. In group chats, WE means chat_id, not sender_id. Never use sender_id for WE/US/OUR questions.
    - sender_id is a real external numeric/string sender id, never the word 'user'.
    - channel is a real channel like 'telegram' or 'signal', never 'main'.
    - session scope is a channel like 'telegram' or 'signal', never 'user'.
    """
    |> String.trim()
  end

  def request_context(_context), do: request_context(%{})

  defp local_datetime_tuple, do: :calendar.local_time()

  defp format_local_datetime({{year, month, day}, {hour, minute, second}}) do
    "#{pad4(year)}-#{pad2(month)}-#{pad2(day)}T#{pad2(hour)}:#{pad2(minute)}:#{pad2(second)}"
  end

  defp format_local_offset(local, utc_now) do
    local_seconds = :calendar.datetime_to_gregorian_seconds(local)

    utc_seconds =
      utc_now
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.to_erl()
      |> :calendar.datetime_to_gregorian_seconds()

    offset_seconds = local_seconds - utc_seconds
    sign = if offset_seconds < 0, do: "-", else: "+"
    abs_seconds = abs(offset_seconds)
    hours = div(abs_seconds, 3600)
    minutes = div(rem(abs_seconds, 3600), 60)

    "#{sign}#{pad2(hours)}:#{pad2(minutes)}"
  end

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
  defp pad4(value), do: value |> Integer.to_string() |> String.pad_leading(4, "0")

  defp context_value(context, key) when is_map(context),
    do: Map.get(context, key) || Map.get(context, to_string(key))

  defp format_context_value(nil), do: "unknown"
  defp format_context_value(value) when is_atom(value), do: to_string(value)
  defp format_context_value(value), do: to_string(value)

  defp sql_literal_hint(nil), do: "<unknown>"
  defp sql_literal_hint(value), do: "'#{escape_sql_literal(to_string(value))}'"

  defp escape_sql_literal(value), do: String.replace(value, "'", "''")
end

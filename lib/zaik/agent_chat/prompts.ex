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
      domain_policy(domain, text),
      request_context(context),
      mode_instruction(domain)
    ]
    |> Enum.join("\n\n")
  end

  def final do
    """
    FINAL ANSWER MODE.
    You have already received supervised TOOL RESULT data.
    Return exactly one valid JSON object and nothing else:
    {"type":"final","answer":"..."}

    Answer only from the TOOL RESULT data. Do not call tools. Do not invent rows, timestamps, tasks, messages, sensor readings, devices, or actions. If SQL results have zero rows, say that no matching rows were found and mention the filter/time window briefly. For home controls, distinguish an accepted command from a verified state change: never claim the physical device reached its target unless the tool result says verified=true. When an action remains unverified, include its action_id or plan_run_id so the user can check or explicitly retry it. Use a natural house-agent voice.
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

      Regex.match?(~r/\bretry(?: the)?(?: home)? action\b/, normalized) ->
        :home_control

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

      home_reading_request?(normalized) ->
        :home_readings

      home_control_request?(text, normalized, opts) ->
        :home_control

      Regex.match?(
        ~r/\b(lily|room|bedroom|nursery|kitchen|bathroom|living room|office|basement|upstairs|downstairs|home|sensor|temperature|temp|humidity|bright|brightness|illuminance|presence|motion|warm|cool|warmer|cooler|change|changed|trend|trending|blind|blinds|shade|shades|preset|presets)\b/,
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

  defp home_reading_request?(normalized_text) do
    question? =
      Regex.match?(
        ~r/\b(what|whats|how|is|are|was|were|has|have|tell|show|check)\b/,
        normalized_text
      )

    reading_field? =
      Regex.match?(
        ~r/\b(temperature|temp|humidity|humid|illuminance|brightness|bright|presence|motion|battery|voltage|linkquality|reading|readings|warm|cool|warmer|cooler|trend|trending)\b/,
        normalized_text
      )

    question? and reading_field?
  end

  defp home_control_request?(text, normalized_text, opts) do
    action? =
      Regex.match?(
        ~r/\b(set|setup|set up|prepare|adjust|move|open|close|stop|raise|lower|turn|make)\b/,
        normalized_text
      )

    home_target? =
      Regex.match?(
        ~r/\b(home|room|bedroom|blind|blinds|shade|shades|cover|covers|preset|presets|ac|air conditioner|bedtime|sleep)\b/,
        normalized_text
      ) or
        known_home_device_match?(normalized_text, opts) or relevant_home_skill?(text)

    action? and home_target?
  end

  defp relevant_home_skill?(text) do
    Zaik.SkillStore.relevant(text)
    |> Enum.any?(&(Map.get(&1, :domain) == "home"))
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

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

  defp domain_policy(:home_control, text) do
    required_tool = home_control_required_tool(text)

    """
    DOMAIN: home control.
    Required action tool: #{required_tool}

    You may use these supervised tools:
    - execute_home_plan for requests requiring two or more coordinated changes. This is preferred for room setups and skills with multiple steps.
    - control_device for one low-risk entity/capability target.
    - retry_home_action only when the user explicitly asks to retry and supplies an existing action ID. Deterministic policy checks live state, timeout, cooldown, and retry budget.
    - control_blind is a temporary compatibility tool for one blind action.
    - get_home_state and sql_query are read tools when state is genuinely needed before planning.

    Valid multi-action shape:
    {"type":"tool_call","tool":"execute_home_plan","args":{"goal":"Set up Lily's room for bedtime with AC","actions":[{"device":"Lily's bedroom left blind","capability":"cover","target":{"state":"CLOSE"}},{"device":"Lily's bedroom right blind","capability":"cover","target":{"preset":"above AC"}}]}}

    Valid single-action shape:
    {"type":"tool_call","tool":"control_device","args":{"device":"Lily's bedroom left blind","capability":"cover","target":{"state":"CLOSE"}}}

    Valid explicit retry shape:
    {"type":"tool_call","tool":"retry_home_action","args":{"action_id":"exact ID supplied by the user"}}

    Rules:
    - Choose actions from relevant skills, current devices, and presets below.
    - Do not invent devices, capabilities, presets, MQTT topics, or MQTT payloads.
    - Use exact device names when calling tools.
    - Put every required change into one execute_home_plan call. Elixir preflights every action and preset before the first command is sent.
    - Blinds are currently low-risk and may be controlled directly.
    - A skill name is context, never a tool name.
    - If a needed device or preset is missing, ask a concise clarification instead of guessing.
    - Never invent or infer an action ID and never retry by reconstructing controls yourself. Only retry_home_action may approve and reconstruct a retry.
    - A tool result with status=accepted means commands were accepted, not that physical target state was verified. Claim physical completion only when verified=true, and include the returned action_id or plan_run_id while it remains unverified.

    #{home_control_context(text)}
    """
    |> String.trim()
  end

  defp domain_policy(:home_readings, text), do: home_readings_domain_policy(text)
  defp domain_policy(domain, _text), do: domain_policy(domain)

  defp home_control_required_tool(text) do
    normalized = normalize_home_name(text)

    cond do
      Regex.match?(~r/\bretry(?: the)?(?: home)? action\b/, normalized) ->
        "retry_home_action"

      Regex.match?(~r/\b(set up|setup|prepare|ready|routine|scene|bedtime)\b/, normalized) ->
        "execute_home_plan"

      true ->
        "control_device"
    end
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

  defp house_identity(:home_control) do
    """
    You are Zaik, a local personal house agent for this household.

    For this request you may choose validated low-risk home-control tools. Elixir will validate every action before anything is sent to MQTT.

    CRITICAL OUTPUT CONTRACT:
    - Return exactly one valid JSON object and nothing else.
    - For an explicit retry with an action ID, return one retry_home_action call.
    - For multiple actions, return one execute_home_plan call containing the complete actions array.
    - For one new action, return one control_device call.
    - After a tool result, return {"type":"final","answer":"..."} unless a read result shows clarification is needed.
    - Never claim physical completion unless a tool result reports verified=true. If it reports status=accepted, say the command or plan was accepted/sent.
    - Do not output markdown, comments, code fences, MQTT topics, or trailing text.
    """
    |> String.trim()
  end

  defp house_identity(:home_readings) do
    """
    You are Zaik, a local personal house agent for this household.

    The domain policy below specifies the one required read tool for this request. Follow that requirement exactly.

    CRITICAL OUTPUT CONTRACT:
    - Return exactly one valid JSON object and nothing else.
    - Before a TOOL RESULT, return exactly one tool call using the required tool and shape from the domain policy.
    - After tool results, answer from the gathered state/rows or request one additional useful tool call allowed by the domain policy.
    - Never invent devices, capabilities, table names, or readings.
    - Do not output markdown, comments, code fences, or trailing text.
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

  defp mode_instruction(:home_control) do
    "HOME CONTROL MODE: For an explicit retry with an action ID return retry_home_action. For two or more coordinated new changes return one complete execute_home_plan call. For one new change return control_device. If required information is missing, return a clarification question."
  end

  defp mode_instruction(:home_readings) do
    "HOME STATE MODE: For current/latest state return get_home_state. For historical, windowed, or trend questions return sql_query. Copy room/device terms from the exact user request. Do not answer before a tool result."
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

  defp home_readings_domain_policy(text) do
    case home_read_mode(text) do
      "get_home_state" -> current_home_readings_policy(text)
      "sql_query" -> historical_home_readings_policy(text)
    end
  end

  defp current_home_readings_policy(text) do
    lookup = home_lookup_hint(text)

    """
    DOMAIN: home sensor readings and trends.
    MODE: current typed state.
    Exact user request: #{text}
    Requested entity lookup text: #{lookup}
    Required and only available tool: get_home_state

    Return exactly this tool-call shape before answering:
    {"type":"tool_call","tool":"get_home_state","args":{"query":"#{lookup}","capability":"requested capability"}}

    Replace requested capability with one of temperature, humidity, illuminance, presence, cover, battery, or linkquality. Do not call SQL for a current/latest value. Do not answer until get_home_state succeeds.
    """
    |> String.trim()
  end

  defp historical_home_readings_policy(text) do
    lookup = home_lookup_hint(text)
    read_mode = home_read_mode(text)

    """
    DOMAIN: home sensor readings and trends.
    Exact user request: #{text}
    Requested entity lookup text: #{lookup}
    Required first tool: #{read_mode}

    TOOL SELECTION IS REQUIRED:
    - If Required first tool is sql_query, the request asks about history/change/a time window. You MUST use sql_query and MUST NOT substitute get_home_state.
    - If Required first tool is get_home_state, the request asks only for current/latest state. You MUST use get_home_state.

    HARD SCHEMA RULES:
    - The database is home.
    - The only readings view is home_readings. Never use sensor_readings, zaik_sensor_readings, home_read, or home_reads.
    - REQUIRED ENTITY PREDICATE for this request: (lower(device_name) LIKE '%#{escape_sql_literal(lookup)}%' OR lower(room) LIKE '%#{escape_sql_literal(lookup)}%'). Copy that predicate exactly into home_readings SQL.
    - Do not use area IDs, snake_case names, exact equality, or backslash-escaped apostrophes as substitutes for the required predicate.

    Available read tools:
    - get_home_state for current/latest typed state. It filters entities by capability so covers cannot mask temperature sensors.
    - sql_query against database home for historical readings, explicit time windows, and trends.

    get_home_state shape:
    {"type":"tool_call","tool":"get_home_state","args":{"query":"exact room/device words from the user request","capability":"requested capability"}}

    Database: home
    SQL may use these views only:
    home_readings(id, device_id, device_name, room, recorded_at, temperature_c, temperature_f, humidity, illuminance, presence, pir_detection, battery, voltage, linkquality, target_distance, payload_json)
    home_devices(id, friendly_name, source, topic, metadata_json, inserted_at, updated_at)
    home_device_presets(device_name, preset_name, capability, target_json, source, created_by, metadata_json, created_at, updated_at)

    Semantics:
    - Device and room names are dynamic. Match the user's room/device words against lower(device_name), lower(room), and home_devices.friendly_name when needed.
    - Always replace example room/device names with the user's actual requested room/device. Never copy "nursery" or "main bedroom" from examples unless the user asked for that room.
    - For a named room/device like "main bedroom", filter lower(device_name) LIKE '%main bedroom%' OR lower(room) LIKE '%main bedroom%'.
    - If a named room/device has no matching home_readings rows, query home_devices with the same name words before saying there is no data.
    - For casual room-state questions like "what is it like in <room>" or "how is <room>", query the latest temperature_f, humidity, illuminance, presence, and linkquality for that room/device.
    - For specific temperature questions, query home_readings with temperature_f IS NOT NULL so blinds/covers with no temperature do not mask the room sensor.
    - For humidity, illuminance, presence, battery, voltage, or linkquality questions, prefer rows where the requested field IS NOT NULL.
    - For recent readings, ORDER BY recorded_at DESC.
    - Prefer temperature_f for household-facing temperature answers.
    - Boolean fields are 1=true, 0=false.
    - Use SQLite date/time syntax, e.g. datetime('now', '-7 days'). Do not use NOW() or INTERVAL.
    - There is no sensor_readings, home_read, or home_reads view. Use home_readings.
    - In home_readings, the device-name column is device_name. There is no device, friendly_name, or room_name column on home_readings. Use room or device_name.
    - Only home_devices has friendly_name. Do not use friendly_name when querying home_readings.
    - Device presets are named remembered target states, not live readings. For example capability='cover' target_json='{"position":71}' means a cover/blind preset target.
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

    For temperature/humidity/illuminance change over a window, compare the newest and oldest non-null readings for the requested field inside exactly that window. For temperature change, include `temperature_f IS NOT NULL`.

    SQL planning constraints:
    - Every room/device literal in a SQL filter must come from the exact user request above. Do not substitute a room name learned from an example or another request.
    - Current/latest state does not need an arbitrary recent time window; use get_home_state instead.
    - Historical temperature SQL must include temperature_f IS NOT NULL inside the requested entity/time filter.
    """
    |> String.trim()
  end

  defp home_read_mode(text) do
    normalized = normalize_home_name(text)

    if Regex.match?(
         ~r/\b(recent|recently|past|last|ago|since|today|tonight|morning|afternoon|evening|yesterday|minute|minutes|hour|hours|day|days|week|weeks|change|changed|changing|trend|trending|getting|warmer|cooler|history|historical|was|were)\b|\bhas been\b|\bhave been\b/,
         normalized
       ) do
      "sql_query"
    else
      "get_home_state"
    end
  end

  defp home_lookup_hint(text) do
    stop_words =
      MapSet.new(~w(
        a an and are as at be been by did do does for from had has have how i in is it its
        like me my of on or our room rooms sensor sensors the this to was were what whats when
        where which who why with you your temperature temp humidity illuminance brightness
        presence motion warm warmer cool cooler changed change changing trend trending current
        currently latest recently recent past last today tonight morning afternoon evening
        minute minutes hour hours day days week weeks s
      ))

    text
    |> normalize_home_name()
    |> String.split(" ", trim: true)
    |> Enum.reject(fn token ->
      MapSet.member?(stop_words, token) or Regex.match?(~r/^\d+$/, token)
    end)
    |> Enum.take(3)
    |> Enum.join(" ")
    |> case do
      "" -> normalize_home_name(text)
      lookup -> lookup
    end
  end

  defp home_control_context(text) do
    """
    RELEVANT SKILLS:
    #{Zaik.SkillStore.relevant(text) |> Zaik.SkillStore.format_for_prompt()}

    CURRENT BLINDS:
    #{format_current_blinds()}

    DEVICE PRESETS:
    #{format_device_presets()}
    """
    |> String.trim()
  rescue
    _ -> "Home-control context is currently unavailable."
  catch
    :exit, _ -> "Home-control context is currently unavailable."
  end

  defp format_current_blinds do
    case safe_blinds() do
      [] ->
        "No known blinds."

      blinds ->
        Enum.map_join(blinds, "\n", fn device ->
          status = Zaik.Home.Blinds.status(device)

          "- #{device.friendly_name}: position=#{format_prompt_value(status.position)} state=#{format_prompt_value(status.state)} linkquality=#{format_prompt_value(status.linkquality)} battery=#{format_prompt_value(status.battery)}"
        end)
    end
  end

  defp format_device_presets do
    case safe_device_presets() do
      [] ->
        "No known device presets."

      presets ->
        Enum.map_join(presets, "\n", fn preset ->
          "- #{preset["device_name"]}: #{preset["preset_name"]} capability=#{preset["capability"]} target=#{Jason.encode!(preset["target"] || %{})}"
        end)
    end
  end

  defp safe_blinds do
    if Process.whereis(Zaik.Home.DeviceStore), do: Zaik.Home.Blinds.list(), else: []
  catch
    :exit, _ -> []
  end

  defp safe_device_presets do
    if Process.whereis(Zaik.Home.DevicePresetStore),
      do: Zaik.Home.DevicePresetStore.list(),
      else: []
  catch
    :exit, _ -> []
  end

  defp format_prompt_value(nil), do: "unknown"
  defp format_prompt_value(value), do: to_string(value)

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

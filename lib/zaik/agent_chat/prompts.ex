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
      registry_tool_contracts(domain, text, context),
      planner_request_context(domain, context),
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

    Answer only from the TOOL RESULT data. Do not call tools. Do not invent rows, timestamps, tasks, messages, sensor readings, devices, or actions. If SQL results have zero rows, say that no matching rows were found and mention the filter/time window briefly. When a home-state result contains multiple entities, report each entity by name with its own relevant value; do not collapse distinct devices into one shared state. For home controls, distinguish an accepted command from a verified state change: never claim the physical device reached its target unless the tool result says verified=true. When an action remains unverified, include its action_id or plan_run_id so the user can check or explicitly retry it. Use a natural house-agent voice.
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
        ~r/\b(?:status|state|check|verify|verified|complete|completed)\b.*\b(?:home\s+)?action\b|\b(?:home\s+)?action\b.*\b(?:status|state|verified|complete|completed)\b/,
        normalized
      ) ->
        :home_action_status

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
        ~r/\b(temperature|temp|humidity|humid|illuminance|brightness|bright|presence|motion|battery|voltage|linkquality|reading|readings|warm|cool|warmer|cooler|trend|trending|mode|modes|privacy|bedtime)\b/,
        normalized_text
      )

    question? and reading_field?
  end

  defp home_control_request?(text, normalized_text, opts) do
    action? =
      Regex.match?(
        ~r/\b(set|setup|set up|prepare|adjust|move|open|close|stop|raise|lower|turn|make|activate|deactivate|cancel)\b/,
        normalized_text
      )

    home_target? =
      Regex.match?(
        ~r/\b(home|room|bedroom|blind|blinds|shade|shades|cover|covers|preset|presets|ac|air conditioner|bedtime|sleep|privacy|mode)\b/,
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
    - activate_home_mode for an explicit expiring bedtime/privacy mode request; this creates policy context and does not directly control devices.
    - get_home_modes to inspect exact active mode IDs and expiry before cancellation.
    - cancel_home_mode only with an exact active mode ID.
    - execute_home_plan for requests requiring two or more coordinated changes. This is preferred for room setups and skills with multiple steps.
    - apply_device_preset for one existing named device preset.
    - capture_device_preset only when the user explicitly asks to save fresh current device state as a preset.
    - control_device for one low-risk entity/capability target.
    - retry_home_action only when the user explicitly asks to retry and supplies an existing action ID. Deterministic policy checks live state, timeout, cooldown, and retry budget.
    - control_blind is a temporary compatibility tool for one blind action.
    - get_home_goal_context gathers required evidence for a relevant versioned goal skill before planning.
    - get_home_state and sql_query are read tools when state is genuinely needed before planning.

    Valid multi-action shape:
    {"type":"tool_call","tool":"execute_home_plan","args":{"goal":"Set up Lily's room for bedtime with AC","goal_id":"lily_bedtime","goal_context_fingerprint":"COPY_EXACT_VALUE_FROM_GOAL_CONTEXT_RESULT","actions":[{"device":"Lily's bedroom left blind","capability":"cover","target":{"state":"CLOSE"}},{"device":"Lily's bedroom right blind","capability":"cover","target":{"preset":"above AC"}}]}}

    Valid single-action shape:
    {"type":"tool_call","tool":"control_device","args":{"device":"Lily's bedroom left blind","capability":"cover","target":{"state":"CLOSE"}}}

    Valid mode activation shape:
    {"type":"tool_call","tool":"activate_home_mode","args":{"scope":"Lily's room","mode":"privacy","ttl_seconds":3600,"reason":"explicit user request"}}

    Valid explicit retry shape:
    {"type":"tool_call","tool":"retry_home_action","args":{"action_id":"exact ID supplied by the user"}}

    Rules:
    - For a relevant skill containing goal_id, call get_home_goal_context with that exact semantic goal ID before proposing actions. If required evidence is missing or stale, ask for clarification and do not execute. Otherwise copy the exact returned goal_id and fingerprint into execute_home_plan as goal_id and goal_context_fingerprint; invented, omitted, or changed evidence is rejected.
    - Choose actions only from the validated goal context, relevant skills, current devices, and presets below.
    - Mode activation requires an explicit bounded duration. Do not invent a permanent mode. Cancellation requires an exact mode ID from the user or get_home_modes.
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

  defp domain_policy(:home_action_status, _text) do
    """
    DOMAIN: home action status.
    Required first tool: get_home_action_status

    Return exactly one read tool call using the action ID supplied by the user:
    {"type":"tool_call","tool":"get_home_action_status","args":{"action_id":"exact action ID"}}

    Never invent an action ID, retry an action, or issue replacement controls.
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

      Regex.match?(~r/\b(cancel|deactivate)\b.*\b(mode|privacy|bedtime)\b/, normalized) ->
        "cancel_home_mode"

      Regex.match?(~r/\b(activate|set)\b.*\b(mode|privacy)\b/, normalized) ->
        "activate_home_mode"

      Regex.match?(~r/\bactivate\b.*\bbedtime\b/, normalized) ->
        "activate_home_mode"

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

  defp house_identity(:home_action_status) do
    """
    You are Zaik, a local personal house agent for this household.

    Return exactly one valid JSON object and nothing else. Before a tool result, call get_home_action_status with only the exact supplied action ID. After the result, explain whether the action is pending, verified, expired, cancelled, failed, or unavailable. Do not retry or control devices.
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
    - For one named preset application or explicit preset capture, use the corresponding preset tool; for another single new action, return one control_device call.
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

  defp planner_request_context(domain, context)
       when domain in [:ops_messages, :ops_tasks, :agent_chat_runs],
       do: request_context(context)

  defp planner_request_context(_domain, context) do
    """
    CURRENT REQUEST CONTEXT:
    channel: #{format_context_value(context_value(context, :channel))}
    sender_id: #{format_context_value(context_value(context, :sender_id) || context_value(context, :sender))}
    chat_id: #{format_context_value(context_value(context, :chat_id))}
    """
    |> String.trim()
  end

  defp registry_tool_contracts(domain, text, context) do
    names = tool_names_for_domain(domain, text)
    registry_opts = Map.get(context, :registry_opts) || Map.get(context, "registry_opts") || []

    contracts =
      registry_opts
      |> Zaik.Tools.Registry.descriptors()
      |> Enum.filter(&(&1.name in names))
      |> Enum.map(fn descriptor ->
        Map.take(descriptor, [:name, :description, :kind, :risk, :input_schema])
      end)

    if contracts == [] do
      "AVAILABLE REGISTERED TOOL CONTRACTS: none"
    else
      "AVAILABLE REGISTERED TOOL CONTRACTS (runtime generated):\n" <> Jason.encode!(contracts)
    end
  end

  defp tool_names_for_domain(:general, _text), do: []
  defp tool_names_for_domain(:home_action_status, _text), do: ["get_home_action_status"]
  defp tool_names_for_domain(:home_readings, text), do: [home_read_mode(text)]
  defp tool_names_for_domain(:home_control, text), do: [home_control_required_tool(text)]
  defp tool_names_for_domain(_domain, _text), do: ["sql_query"]

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

  defp mode_instruction(:home_action_status) do
    "HOME ACTION STATUS MODE: Call get_home_action_status with the exact supplied action ID, then answer from its result. Do not execute or retry actions."
  end

  defp mode_instruction(:home_control) do
    "HOME CONTROL MODE: For an explicit retry with an action ID return retry_home_action. For a relevant multi-step skill, copy every expected plan step with exact device names into one execute_home_plan call; never replace an exact device name with a room name. For one new action return control_device. If required information is missing, return a clarification question."
  end

  defp mode_instruction(:home_readings) do
    "HOME STATE MODE: For current/latest state return get_home_state. For historical, windowed, or trend questions return get_home_history. For a room summary or overall conditions return get_area_context. Copy room/device terms and exact time windows from the request. Do not answer before a tool result."
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
      "get_home_history" -> historical_home_readings_policy(text)
      "get_area_context" -> area_context_policy(text)
      "get_home_modes" -> home_modes_policy(text)
    end
  end

  defp home_modes_policy(text) do
    lookup = home_lookup_hint(text)

    """
    DOMAIN: active household modes.
    Exact user request: #{text}
    Required and only available tool: get_home_modes

    Return exactly this read call before answering:
    {"type":"tool_call","tool":"get_home_modes","args":{"scope":"#{lookup}"}}

    Report exact mode IDs, owners, reasons, and expiry. Do not cancel or activate a mode from a read request.
    """
    |> String.trim()
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

    """
    DOMAIN: home sensor readings and trends.
    MODE: typed historical capability state.
    Exact user request: #{text}
    Requested entity lookup text: #{lookup}
    Required first tool: get_home_history

    Return one bounded typed-history call before answering:
    {"type":"tool_call","tool":"get_home_history","args":{"query":"#{lookup}","capability":"requested capability","since_minutes":30,"limit":100}}

    Rules:
    - Copy the exact entity/room words into query.
    - Use one capability: temperature, temperature_f, humidity, illuminance, presence, pir_detection, battery, voltage, linkquality, or target_distance.
    - Translate an explicit relative duration exactly: 30 minutes -> since_minutes=30, 3 hours -> 180, 2 days -> 2880. Do not collapse different requested time windows into one default.
    - Interpret natural-language time phrases from CURRENT TIME CONTEXT. For calendar bounds such as today or yesterday, use ISO-8601 `from` and `until` instead of guessing a duration.
    - For "recently" with no exact duration, omit bounds and use limit=20.
    - Values are returned oldest to newest with source observation time and provenance. Compare first and last values for a change/trend answer.
    - Do not call sql_query for ordinary capability history. Raw SQL is reserved for advanced cross-domain aggregation.
    """
    |> String.trim()
  end

  defp area_context_policy(text) do
    lookup = home_lookup_hint(text)

    """
    DOMAIN: home room summary and environmental context.
    Exact user request: #{text}
    Requested area lookup text: #{lookup}
    Required first tool: get_area_context

    Return one deterministic area-context call before answering:
    {"type":"tool_call","tool":"get_area_context","args":{"query":"#{lookup}","window_minutes":180,"history_capabilities":["temperature_f","humidity","illuminance","presence"]}}

    Report current entities separately from historical summaries. Preserve status, sample_count, window_minutes, freshness_seconds, provenance, season, and solar_phase semantics. Do not invent missing environmental facts or treat configured day/night hours as astronomical sunrise/sunset.
    """
    |> String.trim()
  end

  defp home_read_mode(text) do
    normalized = normalize_home_name(text)

    cond do
      Regex.match?(~r/\b(mode|modes|privacy mode|bedtime mode)\b/, normalized) ->
        "get_home_modes"

      Regex.match?(
        ~r/\b(recent|recently|past|last|ago|since|today|tonight|morning|afternoon|evening|yesterday|minute|minutes|hour|hours|day|days|week|weeks|change|changed|changing|trend|trending|getting|warmer|cooler|history|historical|was|were)\b|\bhas been\b|\bhave been\b/,
        normalized
      ) ->
        "get_home_history"

      Regex.match?(
        ~r/\b(summary|summarize|overview|overall|conditions)\b|\bhow is\b|\bhow s\b|\bhows\b/,
        normalized
      ) ->
        "get_area_context"

      true ->
        "get_home_state"
    end
  end

  defp home_lookup_hint(text) do
    stop_words =
      MapSet.new(~w(
        a an and are as at be been by conditions did do does for from give had has have how i in is it its
        like me my of on or our overall overview room rooms sensor sensors summary summarize the this to was were what whats when
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

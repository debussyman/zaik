defmodule Zaik.AgentChat do
  @moduledoc """
  Bounded read-only tool-using conversational agent for Zaik.

  Deterministic commands/intents should remain the fast path. This module is for
  follow-up or analytical questions where the model can request trusted tools
  and then produce a grounded answer from tool results.
  """

  require Logger

  @default_model "qwen3-coder:30b"
  @default_max_tool_calls 3

  def config do
    configured = Application.get_env(:zaik, :agent_chat, [])

    %{
      enabled: env_bool("ZAIK_AGENT_CHAT_ENABLED", Keyword.get(configured, :enabled, true)),
      model:
        System.get_env("ZAIK_AGENT_MODEL") || Keyword.get(configured, :model, @default_model),
      num_ctx: env_integer("ZAIK_AGENT_NUM_CTX") || Keyword.get(configured, :num_ctx, 4096),
      num_predict:
        env_integer("ZAIK_AGENT_NUM_PREDICT") || Keyword.get(configured, :num_predict, 900),
      timeout_ms:
        env_integer("ZAIK_AGENT_TIMEOUT_MS") || Keyword.get(configured, :timeout_ms, 45_000),
      keep_alive:
        System.get_env("ZAIK_AGENT_KEEP_ALIVE") || Keyword.get(configured, :keep_alive, "30m"),
      temperature:
        env_float("ZAIK_AGENT_TEMPERATURE") || Keyword.get(configured, :temperature, 0.0),
      max_tool_calls:
        env_integer("ZAIK_AGENT_MAX_TOOL_CALLS") ||
          Keyword.get(configured, :max_tool_calls, @default_max_tool_calls)
    }
  end

  def respond(text, context \\ %{}, opts \\ []) when is_binary(text) do
    cfg = Map.merge(config(), Map.new(Keyword.get(opts, :config, %{})))

    if cfg.enabled do
      client = Keyword.get(opts, :client, Zaik.LLM.OllamaClient)
      sql_tool = Keyword.get(opts, :sql_tool, Zaik.Analytics.SQLTool)

      messages = base_messages(text, context)
      loop(client, sql_tool, messages, cfg, 0)
    else
      {:error, :disabled}
    end
  end

  defp loop(_client, _sql_tool, _messages, cfg, tool_count)
       when tool_count >= cfg.max_tool_calls do
    {:ok,
     "I reached my read-only analysis limit before I could finish. Try asking a narrower question."}
  end

  defp loop(client, sql_tool, messages, cfg, tool_count) do
    with {:ok, result} <-
           client.chat("",
             messages: messages,
             model: cfg.model,
             num_ctx: cfg.num_ctx,
             num_predict: cfg.num_predict,
             temperature: cfg.temperature,
             keep_alive: cfg.keep_alive,
             format: "json",
             think: false,
             timeout_ms: cfg.timeout_ms,
             purpose: :agent_chat
           ),
         {:ok, action} <- decode_action(result.response) do
      case action do
        %{"type" => "final", "answer" => answer} when is_binary(answer) ->
          {:ok, String.trim(answer)}

        %{"type" => "tool_call", "tool" => "sql_query", "args" => args} when is_map(args) ->
          run_sql_tool(client, sql_tool, messages, cfg, tool_count, args)

        _ ->
          {:error, {:invalid_agent_action, action}}
      end
    else
      {:error, reason} ->
        Logger.debug("Agent chat failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp run_sql_tool(client, sql_tool, messages, cfg, tool_count, args) do
    db = args |> Map.get("database", "ops") |> normalize_database()
    query = Map.get(args, "query")
    limit = normalize_limit(Map.get(args, "limit"), 200)

    tool_result =
      if is_binary(query) do
        sql_tool.run(query, db: db, limit: limit)
      else
        {:error, :missing_query}
      end

    tool_message = %{
      role: "user",
      content: """
      SQL TOOL RESULT
      database: #{db}
      query: #{query}
      result_json: #{Jason.encode!(normalize_tool_result(tool_result))}

      Use this SQL TOOL RESULT to answer the user's question. Your next response must be JSON with type "final" unless result_json has ok=false and you need one corrected SQL query.
      """
    }

    assistant_message = %{
      role: "assistant",
      content: Jason.encode!(%{type: "tool_call", tool: "sql_query", args: args})
    }

    final_instruction = %{
      role: "system",
      content:
        "You have received the tool_result. Your next response MUST be JSON with type \"final\" and an answer grounded only in that tool_result. Do not call another tool unless the tool_result contains an error."
    }

    loop(
      client,
      sql_tool,
      messages ++ [assistant_message, tool_message, final_instruction],
      cfg,
      tool_count + 1
    )
  end

  defp base_messages(text, context) do
    [
      %{role: "system", content: system_prompt()},
      %{role: "system", content: conversation_context(context)},
      %{role: "user", content: text}
    ]
  end

  def system_prompt do
    """
    You are Zaik, a read-only conversational home and operations analyst with one tool: sql_query.

    CRITICAL OUTPUT CONTRACT:
    - Return exactly one valid JSON object and nothing else.
    - The top-level JSON key "type" MUST be either "tool_call" or "final".
    - NEVER output type "tool_result" or "conversation_context". Those are sent to you by Elixir only.
    - Do not invent rows, readings, timestamps, messages, or task records.
    - Do not echo the user message as a key.
    - Do not include markdown, comments, code fences, or trailing text.
    - If you need data, return a tool_call. If Elixir has already sent you a tool_result and it is sufficient, return final.

    DECISION POLICY:
    - Questions about what users asked, chat history, sessions, tasks, failures, LLM calls, or watchdog scans MUST call sql_query with database "ops".
    - For questions like "what have we asked you today?", query zaik_messages in database "ops". There is no home_messages table.
    - Questions about Lily's room, home sensors, temperature, humidity, brightness, presence, or historical readings MUST call sql_query with database "home".
    - You may answer directly only for pure conversation or when the answer is already in a prior tool_result.
    - You cannot control devices, write files, execute shell commands, publish MQTT, or mutate databases. If asked to control something, return final explaining confirmation/control tools are not enabled yet.

    VALID JSON SHAPES:
    {"type":"tool_call","tool":"sql_query","args":{"database":"home","query":"SELECT ...","limit":200}}
    {"type":"tool_call","tool":"sql_query","args":{"database":"ops","query":"SELECT ...","limit":200}}
    {"type":"final","answer":"natural language answer grounded in tool results"}

    EXAMPLES:
    User: what have we asked you today?
    Assistant: {"type":"tool_call","tool":"sql_query","args":{"database":"ops","query":"SELECT created_at, channel, sender_id, chat_id, content FROM zaik_messages WHERE role = 'user' AND substr(created_at, 1, 10) = date('now') ORDER BY created_at ASC LIMIT 20","limit":20}}

    User: what tasks failed recently?
    Assistant: {"type":"tool_call","tool":"sql_query","args":{"database":"ops","query":"SELECT id, type, status, completed_at, error_json FROM zaik_tasks WHERE status IN ('failed', 'timed_out', 'cancelled') ORDER BY COALESCE(completed_at, updated_at) DESC LIMIT 10","limit":10}}

    User: has Lily's room been warm recently?
    Assistant: {"type":"tool_call","tool":"sql_query","args":{"database":"home","query":"SELECT recorded_at, temperature_f, humidity, illuminance, presence FROM home_readings WHERE lower(device_name) LIKE '%lily%' ORDER BY recorded_at DESC LIMIT 20","limit":20}}

    When Elixir sends a later user message beginning with "SQL TOOL RESULT", summarize only the rows returned by that SQL TOOL RESULT. Do not output tool_result yourself.

    #{Zaik.Analytics.SQLTool.schema(:ops)}

    #{Zaik.Analytics.SQLTool.schema(:home)}

    SQL rules: use only SELECT or WITH SELECT. Query only the documented views. Never invent table/view names.
    Prefer small LIMITs. Use date('now') for today and datetime('now', '-1 hour') style windows when useful.
    For Lily's room, match device_name with lower(device_name) LIKE '%lily%'.
    Boolean fields are 1=true, 0=false.
    """
    |> String.trim()
  end

  defp conversation_context(%{session_id: session_id}) when is_binary(session_id) do
    recent =
      case Zaik.MemoryStore.recent(session_id, 8) do
        {:ok, entries} -> entries
        _ -> []
      end

    format_conversation_context(session_id, recent)
  rescue
    _ -> "Conversation context: no recent messages."
  catch
    :exit, _ -> "Conversation context: no recent messages."
  end

  defp conversation_context(context) do
    "Conversation context: #{inspect(context, limit: 20)}. No recent messages were loaded."
  end

  defp format_conversation_context(_session_id, []),
    do: "Conversation context: no recent messages."

  defp format_conversation_context(session_id, entries) do
    lines =
      entries
      |> Enum.map(&summarize_entry/1)
      |> Enum.map(fn {role, content} -> "- #{role}: #{content}" end)

    Enum.join(["Conversation context for session #{session_id}:" | lines], "\n")
  end

  defp summarize_entry(%{"type" => "message", "role" => role, "content" => content}),
    do: {role, content}

  defp summarize_entry(entry),
    do: {entry["type"] || "entry", entry["content"] || entry["summary"] || ""}

  defp decode_action(response) when is_binary(response) do
    with {:ok, decoded} <-
           response
           |> String.trim()
           |> strip_code_fence()
           |> Jason.decode() do
      {:ok, normalize_action(decoded)}
    end
  end

  defp normalize_action(%{"type" => "final", "answer" => answer} = action) when is_binary(answer),
    do: action

  defp normalize_action(%{"type" => "final", "text" => text}) when is_binary(text),
    do: %{"type" => "final", "answer" => text}

  defp normalize_action(%{"type" => "conversation_message", "content" => content})
       when is_binary(content),
       do: %{"type" => "final", "answer" => content}

  defp normalize_action(%{"role" => "assistant", "content" => content}) when is_binary(content),
    do: %{"type" => "final", "answer" => content}

  defp normalize_action(%{"type" => type, "args" => args} = action)
       when type in ["tool_call", "tool_request"] and is_map(args) do
    tool = Map.get(action, "tool") || Map.get(action, "tool_name") || Map.get(action, "name")
    normalize_tool_call(tool, args)
  end

  defp normalize_action(%{"type" => type, "arguments" => args} = action)
       when type in ["tool_call", "tool_request"] and is_map(args) do
    tool = Map.get(action, "tool") || Map.get(action, "tool_name") || Map.get(action, "name")
    normalize_tool_call(tool, args)
  end

  defp normalize_action(%{"name" => "tool_call", "arguments" => args}) when is_map(args),
    do: normalize_tool_call("sql_query", args)

  defp normalize_action(%{"tool" => tool, "query" => query} = action) when is_binary(query),
    do: normalize_tool_call(tool, action)

  defp normalize_action(%{"tool_name" => tool, "query" => query} = action) when is_binary(query),
    do: normalize_tool_call(tool, action)

  defp normalize_action(%{"query" => query} = action) when is_binary(query),
    do: normalize_tool_call("sql_query", action)

  defp normalize_action(action), do: action

  defp normalize_tool_call(tool, args) when is_map(args) do
    query = Map.get(args, "query")

    if sql_tool_name?(tool) and is_binary(query) do
      %{
        "type" => "tool_call",
        "tool" => "sql_query",
        "args" => %{
          "database" => infer_database(query, Map.get(args, "database")),
          "query" => query,
          "limit" => Map.get(args, "limit", 200)
        }
      }
    else
      %{"type" => "invalid_tool_call", "tool" => tool, "args" => args}
    end
  end

  defp sql_tool_name?(tool) when tool in ["sql_query", "sql_database_query", "query_database"],
    do: true

  defp sql_tool_name?(_tool), do: false

  defp infer_database(query, requested) do
    downcased = String.downcase(query)

    cond do
      String.contains?(downcased, "zaik_") -> "ops"
      String.contains?(downcased, "home_") -> "home"
      requested in ["ops", "home"] -> requested
      true -> "ops"
    end
  end

  defp strip_code_fence("```json" <> rest),
    do: rest |> String.trim() |> String.trim_trailing("```") |> String.trim()

  defp strip_code_fence("```" <> rest),
    do: rest |> String.trim() |> String.trim_trailing("```") |> String.trim()

  defp strip_code_fence(response), do: response

  defp normalize_database("home"), do: :home
  defp normalize_database(:home), do: :home
  defp normalize_database(_), do: :ops

  defp normalize_limit(value, _default) when is_integer(value), do: max(1, min(value, 500))

  defp normalize_limit(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> normalize_limit(int, default)
      _ -> default
    end
  end

  defp normalize_limit(_value, default), do: default

  defp normalize_tool_result({:ok, result}), do: Map.put(result, :ok, true)
  defp normalize_tool_result({:error, reason}), do: %{ok: false, error: inspect(reason)}
  defp normalize_tool_result(other), do: %{ok: false, error: inspect(other)}

  defp env_bool(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> value |> String.downcase() |> then(&(&1 in ["1", "true", "yes", "on"]))
    end
  end

  defp env_integer(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> nil
        end
    end
  end

  defp env_float(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> nil
        end
    end
  end
end

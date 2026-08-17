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
        env_integer("ZAIK_AGENT_NUM_PREDICT") || Keyword.get(configured, :num_predict, 700),
      timeout_ms:
        env_integer("ZAIK_AGENT_TIMEOUT_MS") || Keyword.get(configured, :timeout_ms, 45_000),
      keep_alive:
        System.get_env("ZAIK_AGENT_KEEP_ALIVE") || Keyword.get(configured, :keep_alive, "30m"),
      temperature:
        env_float("ZAIK_AGENT_TEMPERATURE") || Keyword.get(configured, :temperature, 0.1),
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
      content:
        Jason.encode!(%{
          type: "tool_result",
          tool: "sql_query",
          database: db,
          query: query,
          result: normalize_tool_result(tool_result)
        })
    }

    assistant_message = %{
      role: "assistant",
      content: Jason.encode!(%{type: "tool_call", tool: "sql_query", args: args})
    }

    loop(client, sql_tool, messages ++ [assistant_message, tool_message], cfg, tool_count + 1)
  end

  defp base_messages(text, context) do
    [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: conversation_context(context)},
      %{role: "user", content: text}
    ]
  end

  defp system_prompt do
    """
    You are Zaik, a read-only conversational home and operations analyst.

    You may answer directly only when the answer is obvious from the conversation.
    For facts about the home, tasks, sessions, messages, LLM calls, or watchdog
    state, call the sql_query tool first and answer only from tool results.

    You cannot control devices, write files, execute shell commands, publish MQTT,
    or mutate databases. If asked to control something, say confirmation/control
    tools are not enabled yet.

    Return ONLY valid JSON in one of these shapes:

    {"type":"tool_call","tool":"sql_query","args":{"database":"home","query":"SELECT ...","limit":200}}
    {"type":"tool_call","tool":"sql_query","args":{"database":"ops","query":"SELECT ...","limit":200}}
    {"type":"final","answer":"natural language answer"}

    #{Zaik.Analytics.SQLTool.schema(:home)}

    #{Zaik.Analytics.SQLTool.schema(:ops)}

    SQL rules: use only SELECT or WITH SELECT. Query only the documented views.
    Prefer small LIMITs. Use datetime('now', '-1 hour') style time windows when useful.
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

    Jason.encode!(%{
      type: "conversation_context",
      session_id: session_id,
      recent_messages: Enum.map(recent, &summarize_entry/1)
    })
  rescue
    _ -> Jason.encode!(%{type: "conversation_context", recent_messages: []})
  catch
    :exit, _ -> Jason.encode!(%{type: "conversation_context", recent_messages: []})
  end

  defp conversation_context(context) do
    Jason.encode!(%{type: "conversation_context", context: context, recent_messages: []})
  end

  defp summarize_entry(%{"type" => "message", "role" => role, "content" => content}) do
    %{role: role, content: content}
  end

  defp summarize_entry(entry),
    do: %{type: entry["type"], content: entry["content"] || entry["summary"]}

  defp decode_action(response) when is_binary(response) do
    response
    |> String.trim()
    |> strip_code_fence()
    |> Jason.decode()
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

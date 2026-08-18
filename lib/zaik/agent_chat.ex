defmodule Zaik.AgentChat do
  @moduledoc """
  Bounded read-only tool-using conversational agent for Zaik.

  Deterministic commands/intents should remain the fast path. This module is for
  follow-up or analytical questions where the model can request trusted tools
  and then produce a grounded answer from tool results.
  """

  require Logger

  @default_model "qwen3:4b-instruct"
  @default_fallback_model "qwen3-coder:30b"
  @default_max_tool_calls 3

  def config do
    configured = Application.get_env(:zaik, :agent_chat, [])

    %{
      enabled: env_bool("ZAIK_AGENT_CHAT_ENABLED", Keyword.get(configured, :enabled, true)),
      model:
        System.get_env("ZAIK_AGENT_MODEL") || Keyword.get(configured, :model, @default_model),
      fallback_enabled:
        env_bool("ZAIK_AGENT_FALLBACK_ENABLED", Keyword.get(configured, :fallback_enabled, true)),
      fallback_model:
        System.get_env("ZAIK_AGENT_FALLBACK_MODEL") ||
          Keyword.get(configured, :fallback_model, @default_fallback_model),
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

      messages = base_messages(text, context, Keyword.get(opts, :prompt_domain))
      respond_with_fallback(client, sql_tool, messages, cfg, text, context)
    else
      {:error, :disabled}
    end
  end

  defp respond_with_fallback(client, sql_tool, messages, cfg, text, context) do
    started_mono = System.monotonic_time(:millisecond)
    started_at = DateTime.utc_now()
    primary = run_attempt(client, sql_tool, messages, cfg)

    {public_result, fallback} =
      if fallback_needed?(primary.result) and fallback_available?(cfg) do
        fallback_cfg = %{cfg | model: cfg.fallback_model, fallback_enabled: false}
        reason = fallback_reason(primary.result)

        Logger.info(
          "AgentChat falling back from #{inspect(cfg.model)} to #{inspect(fallback_cfg.model)}: #{inspect(reason)}"
        )

        Zaik.TelemetryStore.safe_record_llm_call(%{
          purpose: :agent_chat_fallback,
          model: fallback_cfg.model,
          success: true,
          metadata: %{
            primary_model: cfg.model,
            fallback_model: fallback_cfg.model,
            reason: inspect(reason)
          }
        })

        fallback = run_attempt(client, sql_tool, messages, fallback_cfg)

        result =
          case fallback.result do
            {:ok, _answer} = ok -> ok
            {:error, fallback_reason} -> {:error, {:fallback_failed, reason, fallback_reason}}
            other -> other
          end

        {result, fallback}
      else
        {primary.result, nil}
      end

    record_run_trace(
      text,
      context,
      cfg,
      primary,
      fallback,
      public_result,
      started_at,
      started_mono
    )

    public_result
  end

  defp fallback_available?(cfg) do
    cfg.fallback_enabled and is_binary(cfg.fallback_model) and cfg.fallback_model != "" and
      cfg.fallback_model != cfg.model
  end

  defp fallback_needed?({:error, _reason}), do: true
  defp fallback_needed?({:ok, answer}) when is_binary(answer), do: low_confidence_answer?(answer)
  defp fallback_needed?(_result), do: false

  defp fallback_reason({:error, reason}), do: reason
  defp fallback_reason({:ok, answer}), do: {:low_confidence_answer, String.slice(answer, 0, 160)}
  defp fallback_reason(other), do: other

  defp low_confidence_answer?(answer) do
    normalized = answer |> String.downcase() |> String.trim()

    normalized == "" or
      String.contains?(normalized, "i reached my read-only analysis limit") or
      String.contains?(normalized, "before i could finish") or
      String.contains?(normalized, "i couldn't finish") or
      String.contains?(normalized, "i could not finish") or
      String.contains?(normalized, "try asking a narrower question")
  end

  defp run_attempt(client, sql_tool, messages, cfg) do
    started_mono = System.monotonic_time(:millisecond)
    {result, tool_calls} = loop(client, sql_tool, messages, cfg, 0, [])

    %{
      model: cfg.model,
      result: result,
      tool_calls: tool_calls,
      duration_ms: System.monotonic_time(:millisecond) - started_mono
    }
  end

  defp loop(_client, _sql_tool, _messages, cfg, tool_count, tool_calls)
       when tool_count >= cfg.max_tool_calls do
    {{:ok,
      "I reached my read-only analysis limit before I could finish. Try asking a narrower question."},
     tool_calls}
  end

  defp loop(client, sql_tool, messages, cfg, tool_count, tool_calls) do
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
          {{:ok, String.trim(answer)}, tool_calls}

        %{"type" => "tool_call", "tool" => "sql_query", "args" => args} when is_map(args) ->
          run_sql_tool(client, sql_tool, messages, cfg, tool_count, tool_calls, args)

        _ ->
          {{:error, {:invalid_agent_action, action}}, tool_calls}
      end
    else
      {:error, reason} ->
        Logger.debug("Agent chat failed: #{inspect(reason)}")
        {{:error, reason}, tool_calls}
    end
  end

  defp run_sql_tool(client, sql_tool, messages, cfg, tool_count, tool_calls, args) do
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
      """
    }

    assistant_message = %{
      role: "assistant",
      content: Jason.encode!(%{type: "tool_call", tool: "sql_query", args: args})
    }

    tool_calls = tool_calls ++ [trace_tool_call(db, query, limit, tool_result)]

    case tool_result do
      {:ok, _result} ->
        {final_answer(client, user_text_from(messages), tool_message, cfg), tool_calls}

      {:error, _reason} ->
        correction_instruction = %{
          role: "system",
          content:
            "The SQL TOOL RESULT contains an error. Return one corrected sql_query tool_call JSON object."
        }

        loop(
          client,
          sql_tool,
          messages ++ [assistant_message, tool_message, correction_instruction],
          cfg,
          tool_count + 1,
          tool_calls
        )
    end
  end

  defp trace_tool_call(db, query, limit, tool_result) do
    %{
      database: db,
      query: query,
      limit: limit,
      ok: match?({:ok, _result}, tool_result),
      row_count: tool_row_count(tool_result),
      error: tool_error(tool_result)
    }
  end

  defp tool_row_count({:ok, %{row_count: row_count}}), do: row_count
  defp tool_row_count({:ok, %{"row_count" => row_count}}), do: row_count
  defp tool_row_count(_tool_result), do: nil

  defp tool_error({:error, reason}), do: inspect(reason)
  defp tool_error(_tool_result), do: nil

  defp record_run_trace(
         text,
         context,
         cfg,
         primary,
         fallback,
         public_result,
         started_at,
         started_mono
       ) do
    final_attempt = fallback || primary

    trace_context = trace_context(context)

    Zaik.TelemetryStore.safe_record_agent_chat_run(%{
      prompt: text,
      context: trace_context,
      channel: Map.get(trace_context, :channel),
      sender_id: Map.get(trace_context, :sender_id) || Map.get(trace_context, :sender),
      chat_id: Map.get(trace_context, :chat_id),
      chat_type: Map.get(trace_context, :chat_type),
      session_id: Map.get(trace_context, :session_id),
      primary_model: primary.model,
      fallback_model: cfg.fallback_model,
      fallback_used: not is_nil(fallback),
      final_model: final_attempt.model,
      status: result_status(public_result),
      answer: result_answer(public_result),
      error: result_error(public_result),
      tool_calls: primary.tool_calls ++ if(is_nil(fallback), do: [], else: fallback.tool_calls),
      duration_ms: System.monotonic_time(:millisecond) - started_mono,
      created_at: started_at,
      metadata: %{
        primary_duration_ms: primary.duration_ms,
        fallback_duration_ms: if(is_nil(fallback), do: nil, else: fallback.duration_ms),
        primary_result: inspect(primary.result, limit: 20),
        fallback_result: if(is_nil(fallback), do: nil, else: inspect(fallback.result, limit: 20))
      }
    })
  end

  defp trace_context(context) when is_map(context) do
    [:channel, :sender_id, :sender, :chat_id, :chat_type, :session_id]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(context, key) || Map.get(context, to_string(key)) do
        nil -> acc
        value -> Map.put(acc, key, to_string(value))
      end
    end)
  end

  defp trace_context(_context), do: %{}

  defp result_status({:ok, _answer}), do: :ok
  defp result_status({:error, _reason}), do: :error
  defp result_status(_other), do: :unknown

  defp result_answer({:ok, answer}) when is_binary(answer), do: answer
  defp result_answer(_result), do: nil

  defp result_error({:error, reason}), do: reason
  defp result_error(_result), do: nil

  defp final_answer(client, user_text, tool_message, cfg) do
    final_messages = [
      %{role: "system", content: Zaik.AgentChat.Prompts.final()},
      %{role: "user", content: "Original user question: #{user_text}"},
      tool_message
    ]

    with {:ok, result} <-
           client.chat("",
             messages: final_messages,
             model: cfg.model,
             num_ctx: cfg.num_ctx,
             num_predict: cfg.num_predict,
             temperature: cfg.temperature,
             keep_alive: cfg.keep_alive,
             format: "json",
             think: false,
             timeout_ms: cfg.timeout_ms,
             purpose: :agent_chat_final
           ),
         {:ok, %{"type" => "final", "answer" => answer}} when is_binary(answer) <-
           decode_action(result.response) do
      {:ok, String.trim(answer)}
    else
      {:ok, action} -> {:error, {:invalid_agent_action, action}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp user_text_from(messages) do
    messages
    |> Enum.filter(&(&1.role == "user"))
    |> List.last()
    |> case do
      %{content: content} -> content
      _ -> ""
    end
  end

  defp base_messages(text, context, prompt_domain) do
    [
      %{role: "system", content: Zaik.AgentChat.Prompts.planner(text, context, prompt_domain)},
      %{role: "user", content: text}
    ]
  end

  def system_prompt, do: Zaik.AgentChat.Prompts.planner("", %{})

  defp decode_action(response) when is_binary(response) do
    normalized_response =
      response
      |> String.trim()
      |> strip_code_fence()

    case Jason.decode(normalized_response) do
      {:ok, decoded} -> {:ok, normalize_action(decoded)}
      {:error, _reason} -> decode_non_json_action(normalized_response)
    end
  end

  defp decode_non_json_action(response) do
    if sql_query_text?(response) do
      {:ok, normalize_tool_call("sql_query", %{"query" => response})}
    else
      {:error, %Jason.DecodeError{data: response, position: 0, token: nil}}
    end
  end

  defp sql_query_text?(text) when is_binary(text) do
    downcased = text |> String.trim() |> String.downcase()
    String.starts_with?(downcased, "select ") or String.starts_with?(downcased, "with ")
  end

  defp normalize_action(%{"type" => "final", "answer" => answer} = action) when is_binary(answer),
    do: action

  defp normalize_action(%{"type" => "final", "text" => text}) when is_binary(text),
    do: %{"type" => "final", "answer" => text}

  defp normalize_action(%{"type" => "final", "content" => content}) when is_binary(content),
    do: %{"type" => "final", "answer" => content}

  defp normalize_action(%{"type" => "final", "response" => response}) when is_binary(response),
    do: %{"type" => "final", "answer" => response}

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

  defp normalize_action(%{"name" => tool, "arguments" => args}) when is_map(args),
    do: normalize_tool_call(tool, args)

  defp normalize_action(%{"tool_call" => %{"name" => tool, "arguments" => args}})
       when is_map(args),
       do: normalize_tool_call(tool, args)

  defp normalize_action(%{"tool_call" => %{"tool" => tool, "args" => args}}) when is_map(args),
    do: normalize_tool_call(tool, args)

  defp normalize_action(%{"tool" => tool, "query" => query} = action) when is_binary(query),
    do: normalize_tool_call(tool, action)

  defp normalize_action(%{"tool_name" => tool, "query" => query} = action) when is_binary(query),
    do: normalize_tool_call(tool, action)

  defp normalize_action(%{"query" => query} = action) when is_binary(query),
    do: normalize_tool_call("sql_query", action)

  defp normalize_action(%{"sql_query" => query}) when is_binary(query),
    do: normalize_tool_call("sql_query", %{"query" => query})

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

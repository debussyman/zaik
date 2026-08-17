defmodule Zaik.ChatRouter do
  @moduledoc """
  Natural-language entrypoint for Zaik chat surfaces.

  Explicit commands are still handled by `Zaik.CommandProcessor`. Free-form text
  is classified by `Zaik.Intent.Parser` and dispatched to trusted internal
  command handlers.
  """

  require Logger

  def process(text, context \\ %{}, opts \\ [])

  def process(text, context, opts) when is_binary(text) do
    command_response = Zaik.CommandProcessor.process(text, context)

    if explicit_command_response?(command_response) do
      command_response
    else
      route_freeform(text, context, opts)
    end
  end

  def process(_text, _context, _opts), do: Zaik.CommandProcessor.help()

  def route_freeform(text, context \\ %{}, opts \\ []) do
    parser = Keyword.get(opts, :parser, Zaik.Intent.Parser)
    parser_opts = Keyword.get(opts, :parser_opts, [])

    case parser.parse(text, parser_opts) do
      {:ok, intent} ->
        dispatch_intent(intent, text, context, opts)

      {:error, reason} ->
        Logger.debug("Intent parsing failed: #{inspect(reason)}")
        route_agent_chat(text, context, opts)
    end
  end

  def dispatch_intent(intent, text, context, opts \\ [])

  def dispatch_intent(%{intent: :home_status}, _text, context, _opts),
    do: Zaik.CommandProcessor.process("home", context)

  def dispatch_intent(%{intent: :home_sensor_status, device_query: nil}, _text, context, _opts),
    do: Zaik.CommandProcessor.process("home sensors", context)

  def dispatch_intent(%{intent: :home_sensor_status, device_query: query}, _text, context, _opts),
    do: Zaik.CommandProcessor.process("sensor #{query}", context)

  def dispatch_intent(%{intent: :home_sensor_trend, device_query: nil}, _text, context, _opts),
    do: Zaik.CommandProcessor.process("home trends", context)

  def dispatch_intent(%{intent: :home_sensor_trend, device_query: query}, _text, context, _opts),
    do: Zaik.CommandProcessor.process("sensor #{query} trend", context)

  def dispatch_intent(%{intent: :home_presence_status, device_query: nil}, _text, context, _opts),
    do: Zaik.CommandProcessor.process("presence", context)

  def dispatch_intent(
        %{intent: :home_presence_status, device_query: query},
        _text,
        context,
        _opts
      ),
      do: Zaik.CommandProcessor.process("sensor #{query}", context)

  def dispatch_intent(%{intent: :system_health}, _text, context, _opts),
    do: Zaik.CommandProcessor.process("health", context)

  def dispatch_intent(%{intent: :watchdog_scan}, _text, context, _opts),
    do: Zaik.CommandProcessor.process("watchdog scan", context)

  def dispatch_intent(%{intent: :llm_general_question}, text, context, _opts),
    do: Zaik.CommandProcessor.process("ask #{text}", context)

  def dispatch_intent(%{intent: :unknown}, text, context, opts),
    do: route_agent_chat(text, context, opts)

  def dispatch_intent(_intent, text, context, opts),
    do: route_agent_chat(text, context, opts)

  defp route_agent_chat(text, context, opts) do
    if Keyword.get(opts, :agent_chat_enabled, true) do
      agent_opts = Keyword.get(opts, :agent_chat_opts, [])

      case Zaik.AgentChat.respond(text, context, agent_opts) do
        {:ok, response} -> response
        {:error, _reason} -> fallback_response()
      end
    else
      fallback_response()
    end
  end

  defp fallback_response,
    do:
      "I'm not sure how to route that yet. Try asking about home, Lily's room, Zaik health, or use `help`."

  defp explicit_command_response?(response) when is_binary(response),
    do: not String.starts_with?(response, "Unknown command.")

  defp explicit_command_response?(_response), do: false
end

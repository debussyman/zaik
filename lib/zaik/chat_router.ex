defmodule Zaik.ChatRouter do
  @moduledoc """
  Normal chat entrypoint for Zaik surfaces.

  Free-form chat is handled by one house-agent brain: `Zaik.AgentChat`.
  `Zaik.CommandProcessor` remains available for explicit diagnostic/control
  commands such as `health`, `help`, `ask`, and `watchdog scan`, but natural
  language is not split across a separate intent router or raw LLM task.
  """

  def process(text, context \\ %{}, opts \\ [])

  def process(text, context, opts) when is_binary(text) do
    command_response = Zaik.CommandProcessor.process(text, context)

    if explicit_command_response?(command_response) do
      command_response
    else
      route_house_agent(text, context, opts)
    end
  end

  def process(_text, _context, _opts), do: Zaik.CommandProcessor.help()

  def route_freeform(text, context \\ %{}, opts \\ []), do: route_house_agent(text, context, opts)

  defp route_house_agent(text, context, opts) do
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
      "I'm not sure how to answer that yet. Try asking about home, a known room/sensor, Zaik health, or use `help`."

  defp explicit_command_response?(response) when is_binary(response),
    do: not String.starts_with?(response, "Unknown command.")

  defp explicit_command_response?(_response), do: false
end

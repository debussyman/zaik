defmodule Zaik.ChatRouterTest do
  use ExUnit.Case, async: false

  defmodule HouseAgentClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)
      user_message = messages |> List.last() |> Map.fetch!(:content)
      system_prompt = messages |> hd() |> Map.fetch!(:content)

      send(self(), {:house_agent_called, user_message, system_prompt})

      {:ok,
       %{
         response:
           Jason.encode!(%{
             "type" => "final",
             "answer" => "HouseAgent answered: #{user_message}"
           })
       }}
    end
  end

  setup do
    Zaik.Home.DeviceStore.reset()
    Zaik.Home.HistoryStore.reset()
    :ok
  end

  test "explicit commands still bypass the house agent" do
    response =
      Zaik.ChatRouter.process("health", %{}, agent_chat_opts: [client: HouseAgentClient])

    assert response =~ "Zaik is"
    refute_received {:house_agent_called, _message, _prompt}
  end

  test "free-form home questions use the single house-agent brain" do
    response =
      Zaik.ChatRouter.process("What was Lily's temperature change in the past 30 minutes?", %{},
        agent_chat_opts: [
          client: HouseAgentClient,
          config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
        ]
      )

    assert response =~ "HouseAgent answered"
    assert_received {:house_agent_called, user_message, system_prompt}
    assert user_message =~ "past 30 minutes"
    assert system_prompt =~ "You are Zaik, a local personal house agent"
    assert system_prompt =~ "home_readings"
    assert system_prompt =~ "CURRENT TIME CONTEXT"
    assert system_prompt =~ "Interpret natural-language time phrases"
    assert system_prompt =~ "Do not collapse different requested time windows"
  end

  test "free-form ops/memory questions use the same house-agent brain" do
    response =
      Zaik.ChatRouter.process(
        "what questions have we asked you recently",
        %{channel: :telegram, sender_id: "111", chat_id: "-100", chat_type: "group"},
        agent_chat_opts: [
          client: HouseAgentClient,
          config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
        ]
      )

    assert response =~ "HouseAgent answered"
    assert_received {:house_agent_called, _user_message, system_prompt}
    assert system_prompt =~ "zaik_messages"
    assert system_prompt =~ "chat_id = '-100'"
    assert system_prompt =~ "Do not claim you cannot access prior conversations"
  end

  test "free-form general questions also use the house-agent brain instead of raw LLM tasks" do
    response =
      Zaik.ChatRouter.process("what is photosynthesis?", %{},
        agent_chat_opts: [
          client: HouseAgentClient,
          config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
        ]
      )

    assert response =~ "HouseAgent answered: what is photosynthesis?"
    refute response =~ "LLM task"
    assert_received {:house_agent_called, "what is photosynthesis?", system_prompt}
    assert system_prompt =~ ~s({"type":"final","answer":"..."})
    assert system_prompt =~ "DOMAIN: general conversation"
    refute system_prompt =~ "DOMAIN: home sensor readings"
  end

  test "disabled house agent returns a helpful fallback" do
    response =
      Zaik.ChatRouter.process("florp the blorb", %{}, agent_chat_enabled: false)

    assert response =~ "I'm not sure"
  end
end

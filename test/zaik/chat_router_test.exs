defmodule Zaik.ChatRouterTest do
  use ExUnit.Case, async: false

  defmodule TrendParser do
    def parse(_text, _opts) do
      {:ok,
       %{
         intent: :home_sensor_trend,
         device_query: "lily",
         fields: ["temperature"],
         time_window: "last hour",
         confidence: 0.95
       }}
    end
  end

  defmodule HealthParser do
    def parse(_text, _opts), do: {:ok, %{intent: :system_health, confidence: 0.95}}
  end

  defmodule UnknownParser do
    def parse(_text, _opts), do: {:ok, %{intent: :unknown, confidence: 0.1}}
  end

  defmodule GeneralQuestionParser do
    def parse(_text, _opts), do: {:ok, %{intent: :llm_general_question, confidence: 0.95}}
  end

  defmodule AgentChatParser do
    def parse(_text, _opts), do: {:ok, %{intent: :agent_chat, confidence: 0.95}}
  end

  defmodule MemoryAgentClient do
    def chat(_prompt, opts) do
      messages = Keyword.fetch!(opts, :messages)
      send(self(), {:agent_system_prompt, messages |> hd() |> Map.fetch!(:content)})

      {:ok,
       %{
         response:
           Jason.encode!(%{
             "type" => "final",
             "answer" => "You recently asked about Lily's room and Zaik's model fallback."
           })
       }}
    end
  end

  setup do
    Zaik.Home.DeviceStore.reset()
    Zaik.Home.HistoryStore.reset()
    :ok
  end

  test "explicit commands bypass intent parsing" do
    response = Zaik.ChatRouter.process("health", %{}, parser: UnknownParser)

    assert response =~ "Zaik is"
  end

  test "free-form home trend routes through existing sensor trend command" do
    now = DateTime.utc_now()

    Zaik.Home.DeviceStore.upsert_device("Lily's room multi-sensor", %{"temperature" => 26.0})

    Zaik.Home.HistoryStore.record_device(
      "Lily's room multi-sensor",
      %{"temperature" => 27.0},
      %{},
      observed_at: DateTime.add(now, -3500, :second)
    )

    Zaik.Home.HistoryStore.record_device(
      "Lily's room multi-sensor",
      %{"temperature" => 26.0},
      %{},
      observed_at: now
    )

    response =
      Zaik.ChatRouter.process("Has Lily's room cooled off?", %{}, parser: TrendParser)

    assert response =~ "Lily's room is cooling."
    assert response =~ "It is now 78.8°F, down 1.8°F"
  end

  test "free-form health routes to health command" do
    response = Zaik.ChatRouter.process("Is Zaik healthy?", %{}, parser: HealthParser)

    assert response =~ "Zaik is"
    assert response =~ "Queue:"
  end

  test "general LLM intent routes through house AgentChat instead of raw ask task" do
    response =
      Zaik.ChatRouter.process(
        "what is photosynthesis?",
        %{channel: :telegram, sender_id: "111", chat_id: "-100", chat_type: "group"},
        parser: GeneralQuestionParser,
        agent_chat_opts: [
          client: MemoryAgentClient,
          config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
        ]
      )

    assert response =~ "recently asked"
    refute response =~ "LLM task"
    assert_received {:agent_system_prompt, prompt}
    assert prompt =~ "DOMAIN: general conversation"
    assert prompt =~ ~s({"type":"final","answer":"..."})
  end

  test "agent_chat intent routes to SQL-backed house memory prompt" do
    response =
      Zaik.ChatRouter.process(
        "what questions have we asked you recently",
        %{channel: :telegram, sender_id: "111", chat_id: "-100", chat_type: "group"},
        parser: AgentChatParser,
        agent_chat_opts: [
          client: MemoryAgentClient,
          config: %{enabled: true, fallback_enabled: false, max_tool_calls: 3}
        ]
      )

    assert response =~ "recently asked"
    refute response =~ "LLM task"
    assert_received {:agent_system_prompt, prompt}
    assert prompt =~ "DOMAIN: ops message history"
    assert prompt =~ "Return one sql_query tool_call"
  end

  test "unknown intents get a helpful chat response" do
    response =
      Zaik.ChatRouter.process("florp the blorb", %{},
        parser: UnknownParser,
        agent_chat_enabled: false
      )

    assert response =~ "I'm not sure"
  end
end

defmodule Zaik.Intent.ParserTest do
  use ExUnit.Case, async: true

  defmodule FakeClient do
    def chat(_prompt, opts) do
      send(self(), {:chat_opts, opts})

      {:ok,
       %{
         response:
           Jason.encode!(%{
             "intent" => "home_sensor_trend",
             "device_query" => "lily",
             "fields" => ["temperature", "bogus"],
             "time_window" => "last hour",
             "confidence" => 0.95
           })
       }}
    end
  end

  test "parses structured JSON intent from Ollama client" do
    assert {:ok, intent} =
             Zaik.Intent.Parser.parse("Has Lily's room cooled off?",
               client: FakeClient,
               model: "fake-intent"
             )

    assert intent.intent == :home_sensor_trend
    assert intent.device_query == "lily"
    assert intent.fields == ["temperature"]
    assert intent.time_window == "last hour"
    assert intent.confidence == 0.95

    assert_received {:chat_opts, opts}
    assert Keyword.fetch!(opts, :model) == "fake-intent"
    assert Keyword.fetch!(opts, :format) == "json"
    assert Keyword.fetch!(opts, :think) == false
    assert Keyword.fetch!(opts, :temperature) == 0.0
  end

  defmodule AgentChatClient do
    def chat(_prompt, _opts),
      do:
        {:ok,
         %{
           response:
             Jason.encode!(%{
               "intent" => "agent_chat",
               "device_query" => nil,
               "fields" => [],
               "time_window" => "recently",
               "confidence" => 0.9
             })
         }}
  end

  test "parses agent_chat intent for house memory questions" do
    assert {:ok, intent} =
             Zaik.Intent.Parser.parse("what questions have we asked you recently?",
               client: AgentChatClient
             )

    assert intent.intent == :agent_chat
    assert intent.time_window == "recently"
    assert intent.confidence == 0.9
  end

  defmodule UnknownClient do
    def chat(_prompt, _opts),
      do: {:ok, %{response: Jason.encode!(%{"intent" => "delete_everything"})}}
  end

  test "unknown intent strings normalize to unknown" do
    assert {:ok, intent} = Zaik.Intent.Parser.parse("do something", client: UnknownClient)
    assert intent.intent == :unknown
    assert intent.confidence == 0.0
  end
end

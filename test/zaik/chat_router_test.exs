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

  test "unknown intents get a helpful chat response" do
    response = Zaik.ChatRouter.process("florp the blorb", %{}, parser: UnknownParser)

    assert response =~ "I'm not sure"
  end
end

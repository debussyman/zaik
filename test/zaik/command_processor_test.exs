defmodule Zaik.CommandProcessorBlindsTestPublisher do
  def publish(topic, payload, _opts) do
    Agent.update(__MODULE__, &[{topic, payload} | &1])
    :ok
  end

  def published do
    Agent.get(__MODULE__, &Enum.reverse/1)
  end
end

defmodule Zaik.CommandProcessorTest do
  use ExUnit.Case, async: false

  test "health returns readable harness status" do
    response = Zaik.CommandProcessor.process("health")

    assert response =~ "Zaik is"
    assert response =~ "Queue:"
    assert response =~ "Running:"
  end

  test "tasks returns task summary" do
    response = Zaik.CommandProcessor.process("tasks")

    assert response =~ "Tasks"
    assert response =~ "Queued:"
    assert response =~ "Succeeded:"
  end

  test "submit echo runs through task harness" do
    response = Zaik.CommandProcessor.process("submit echo hello")

    assert response =~ "Submitted echo task"
    assert response =~ "Result: hello"
  end

  test "system runs system_status workload" do
    response = Zaik.CommandProcessor.process("system")

    assert response =~ "System status task"
    assert response =~ "Processes:"
    assert response =~ "Schedulers:"
  end

  test "ask without prompt returns usage" do
    assert Zaik.CommandProcessor.process("ask ") =~ "Usage: ask <prompt>"
  end

  test "home commands expose latest device state" do
    Zaik.Home.DeviceStore.reset()

    Zaik.Home.DeviceStore.upsert_device("Lily presence sensor", %{
      "presence" => true,
      "pir_detection" => false,
      "target_distance" => 0,
      "temperature" => 26.32,
      "humidity" => 57.95,
      "illuminance" => 305,
      "battery" => 100
    })

    home_devices = Zaik.CommandProcessor.process("home devices")
    assert home_devices =~ "Lily presence sensor"
    assert home_devices =~ "79.4°F"

    assert Zaik.CommandProcessor.process("presence") =~ "presence=true"

    sensor = Zaik.CommandProcessor.process("sensor lily")
    assert String.starts_with?(sensor, "Lily's room is bright and hot.")
    assert sensor =~ "The temperature is 79.4°F, humidity is 58%, and illuminance is 305 lux."
    assert sensor =~ "Presence is detected, PIR motion is inactive, and target distance is 0."
    refute sensor =~ "Battery is"
    refute sensor =~ "Configuration:"
    refute sensor =~ "Sensor:"
    refute sensor =~ "Metadata"
    assert sensor |> String.split("\n") |> length() == 3
  end

  test "sensor summary handles possessive room names" do
    Zaik.Home.DeviceStore.reset()

    Zaik.Home.DeviceStore.upsert_device("Lily's room multi-sensor", %{
      "temperature" => 26.28,
      "humidity" => 53.5,
      "illuminance" => 640
    })

    sensor = Zaik.CommandProcessor.process("sensor lily")
    assert String.starts_with?(sensor, "Lily's room is bright and hot.")
    assert sensor =~ "The temperature is 79.3°F, humidity is 53.5%, and illuminance is 640 lux."
  end

  test "sensor command prefers sensor devices over matching blinds" do
    Zaik.Home.DeviceStore.reset()

    Zaik.Home.DeviceStore.upsert_device("Lily's bedroom left blind", %{
      "position" => 100,
      "state" => "OPEN",
      "linkquality" => 100
    })

    Zaik.Home.DeviceStore.upsert_device("Lily's room multi-sensor", %{
      "temperature" => 26.68,
      "humidity" => 52.38,
      "illuminance" => 1,
      "presence" => false
    })

    sensor = Zaik.CommandProcessor.process("sensor lily")
    assert sensor =~ "temperature is 80°F"
    refute sensor =~ "ambiguous"
  end

  test "blinds commands list, capture presets, and publish validated controls" do
    original = Application.get_env(:zaik, :blinds)

    Application.put_env(
      :zaik,
      :blinds,
      Keyword.put(original || [], :mqtt_client, Zaik.CommandProcessorBlindsTestPublisher)
    )

    on_exit(fn -> Application.put_env(:zaik, :blinds, original || []) end)

    {:ok, _publisher} =
      Agent.start_link(fn -> [] end, name: Zaik.CommandProcessorBlindsTestPublisher)

    Zaik.Home.DeviceStore.reset()
    Zaik.Home.DevicePresetStore.reset()

    Zaik.Home.DeviceStore.upsert_device("Lily's bedroom left blind", %{
      "position" => 37,
      "state" => "OPEN",
      "linkquality" => 104
    })

    Zaik.Home.DeviceStore.upsert_device("Lily's bedroom right blind", %{
      "position" => 37,
      "state" => "OPEN",
      "linkquality" => 104
    })

    list = Zaik.CommandProcessor.process("blinds lily")
    assert list =~ "Lily's bedroom left blind"
    assert list =~ "position=37"
    assert list =~ "battery=unknown"

    capture =
      Zaik.CommandProcessor.process("blinds lily left capture above air conditioner", %{
        sender_id: "u1"
      })

    assert capture ==
             ~s(Captured Lily's bedroom left blind preset "above air conditioner" as position=37.)

    set = Zaik.CommandProcessor.process("blinds lily left set above air conditioner")
    assert set == "Sent position=37 to Lily's bedroom left blind."

    stop = Zaik.CommandProcessor.process("blinds lily right stop")
    assert stop == "Sent state=STOP to Lily's bedroom right blind."

    assert Zaik.CommandProcessorBlindsTestPublisher.published() == [
             {"zigbee2mqtt/Lily's bedroom left blind/set", %{"position" => 37}},
             {"zigbee2mqtt/Lily's bedroom right blind/set", %{"state" => "STOP"}}
           ]
  end

  test "sensor trend summarizes history" do
    Zaik.Home.DeviceStore.reset()
    Zaik.Home.HistoryStore.reset()

    Zaik.Home.DeviceStore.upsert_device("Lily's room multi-sensor", %{"temperature" => 26.0})

    now = DateTime.utc_now()

    Zaik.Home.HistoryStore.record_device(
      "Lily's room multi-sensor",
      %{"temperature" => 27.0, "humidity" => 55, "illuminance" => 100},
      %{},
      observed_at: DateTime.add(now, -3500, :second)
    )

    Zaik.Home.HistoryStore.record_device(
      "Lily's room multi-sensor",
      %{"temperature" => 26.0, "humidity" => 54, "illuminance" => 200},
      %{},
      observed_at: now
    )

    response = Zaik.CommandProcessor.process("sensor lily trend")
    assert response =~ "Lily's room is cooling."
    assert response =~ "It is now 78.8°F, down 1.8°F"
    assert response =~ "Based on 2 readings"
  end

  test "alert commands create, list, and cancel presence alerts" do
    Zaik.Alerts.RuleStore.reset()

    response =
      Zaik.CommandProcessor.process("alert presence until 2099-01-01", %{
        channel: :telegram,
        chat_id: "chat-1",
        sender_id: "user-1"
      })

    assert response =~ "Created presence alert alert_"
    assert response =~ "Cooldown: 15m"

    [rule] = Zaik.Alerts.list(:active)
    assert rule["notify_chat_id"] == "chat-1"
    assert rule["created_by"] == "user-1"

    alerts = Zaik.CommandProcessor.process("alerts")
    assert alerts =~ "Active alerts"
    assert alerts =~ rule["id"]
    assert alerts =~ "triggered=0"

    cancel = Zaik.CommandProcessor.process("alert cancel #{rule["id"]}")
    assert cancel == "Cancelled alert #{rule["id"]}."
    assert Zaik.Alerts.list(:active) == []
  end

  test "alert creation requires a chat context" do
    assert Zaik.CommandProcessor.process("alert presence until 2099-01-01") =~
             "must be run from a Telegram chat"
  end

  test "unknown command returns help" do
    response = Zaik.CommandProcessor.process("do unsafe thing")

    assert response =~ "Unknown command"
    assert response =~ "Zaik commands:"
    assert response =~ "ask <prompt>"
  end
end

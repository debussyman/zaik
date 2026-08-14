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
    assert sensor =~ "Sensor: Lily presence sensor."
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

  test "unknown command returns help" do
    response = Zaik.CommandProcessor.process("do unsafe thing")

    assert response =~ "Unknown command"
    assert response =~ "Zaik commands:"
    assert response =~ "ask <prompt>"
  end
end

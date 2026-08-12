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

  test "unknown command returns help" do
    response = Zaik.CommandProcessor.process("do unsafe thing")

    assert response =~ "Unknown command"
    assert response =~ "Zaik commands:"
    assert response =~ "ask <prompt>"
  end
end

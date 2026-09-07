defmodule Zaik.ApplicationTest do
  use ExUnit.Case, async: false

  test "runtime composition can disable domains and adapters" do
    old_domains = Application.get_env(:zaik, :domains)
    old_adapters = Application.get_env(:zaik, :adapters)

    on_exit(fn ->
      restore(:domains, old_domains)
      restore(:adapters, old_adapters)
    end)

    Application.put_env(:zaik, :domains, home: false, operations: true, agents: true)
    Application.put_env(:zaik, :adapters, mqtt: false, telegram: false, signal: false)

    children = Zaik.Application.children()
    rendered = inspect(children)

    refute rendered =~ "Zaik.Home.DeviceStore"
    refute rendered =~ "Zaik.MQTT.Client"
    refute rendered =~ "TelegramPoller"
    assert rendered =~ "Zaik.TaskStore"
    assert rendered =~ "Zaik.Agent.DynamicSupervisor"
  end

  defp restore(key, nil), do: Application.delete_env(:zaik, key)
  defp restore(key, value), do: Application.put_env(:zaik, key, value)
end

defmodule Zaik.MQTT.ClientTest do
  use ExUnit.Case, async: false

  defmodule FakeHandler do
    @behaviour Zaik.MQTT.Handler

    @impl true
    def handle_publish(topic, payload, opts) do
      send(Process.whereis(:zaik_mqtt_client_test), {:mqtt_handler_called, topic, payload, opts})
      :ok
    end
  end

  setup do
    Process.register(self(), :zaik_mqtt_client_test)

    on_exit(fn ->
      if Process.whereis(:zaik_mqtt_client_test), do: Process.unregister(:zaik_mqtt_client_test)
    end)

    :ok
  end

  test "config defaults to Zigbee2MQTT as the MQTT handler" do
    assert Zaik.MQTT.Client.config().handlers == [Zaik.Home.Zigbee2MQTT]
  end

  test "subscription lines fan out to configured handlers" do
    pid =
      start_supervised!(
        {Zaik.MQTT.Client,
         name: nil,
         enabled: false,
         handlers: [FakeHandler, {FakeHandler, source: :second_handler}]}
      )

    send(pid, {make_ref(), {:data, {:eol, "zigbee2mqtt/Test\t{\"presence\":true}"}}})

    assert_receive {:mqtt_handler_called, "zigbee2mqtt/Test", "{\"presence\":true}", []}

    assert_receive {:mqtt_handler_called, "zigbee2mqtt/Test", "{\"presence\":true}",
                    [source: :second_handler]}
  end

  test "subscription lines without delimiter are ignored" do
    pid =
      start_supervised!({Zaik.MQTT.Client, name: nil, enabled: false, handlers: [FakeHandler]})

    send(pid, {make_ref(), {:data, {:eol, "not a formatted mqtt line"}}})

    refute_receive {:mqtt_handler_called, _topic, _payload, _opts}, 50
  end
end

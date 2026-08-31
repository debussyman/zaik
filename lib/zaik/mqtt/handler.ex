defmodule Zaik.MQTT.Handler do
  @moduledoc """
  Behaviour for modules that consume MQTT subscription messages.

  `Zaik.MQTT.Client` is transport-oriented: it connects to the broker,
  subscribes to topics, and fans published messages out to configured handlers.
  Domain/adaptor modules such as Zigbee2MQTT implement this behaviour.
  """

  @callback handle_publish(topic :: String.t(), payload :: String.t(), opts :: keyword()) ::
              term()
end

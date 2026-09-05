defmodule Zaik.Home.Capability do
  @moduledoc """
  Contract for deriving typed home state and accepted targets from adapter data.

  Capabilities describe domain semantics; adapters such as Zigbee2MQTT only
  provide device identity, metadata, and protocol payloads.
  """

  @type descriptor :: %{
          required(:id) => String.t(),
          required(:description) => String.t(),
          required(:state_schema) => map(),
          required(:target_schema) => map() | nil
        }

  @callback descriptor() :: descriptor()
  @callback detected?(device :: map()) :: boolean()
  @callback state(device :: map()) :: map()
  @callback validate_target(target :: map()) :: {:ok, map()} | {:error, term()}
end

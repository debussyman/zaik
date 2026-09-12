defmodule Zaik.Home.Capabilities.Payload do
  @moduledoc false

  def value(device, key) do
    payload = Map.get(device, :payload) || Map.get(device, "payload") || %{}

    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> Map.get(payload, String.to_atom(key))
    end
  end

  def present?(device, key), do: not is_nil(value(device, key))

  def numeric(device, key) do
    case value(device, key) do
      number when is_integer(number) or is_float(number) ->
        number

      string when is_binary(string) ->
        case Float.parse(string) do
          {number, ""} -> number
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def read_only(_target), do: {:error, :read_only_capability}
end

defmodule Zaik.Home.Capabilities.Temperature do
  @moduledoc false
  @behaviour Zaik.Home.Capability
  alias Zaik.Home.Capabilities.Payload

  def descriptor,
    do: %{
      id: "temperature",
      description: "Ambient temperature",
      state_schema: %{"celsius" => "number", "fahrenheit" => "number"},
      target_schema: nil
    }

  def detected?(device), do: not is_nil(Payload.numeric(device, "temperature"))

  def state(device) do
    celsius = Payload.numeric(device, "temperature")
    %{celsius: celsius, fahrenheit: celsius * 9 / 5 + 32}
  end

  defdelegate validate_target(target), to: Payload, as: :read_only
end

defmodule Zaik.Home.Capabilities.Humidity do
  @moduledoc false
  @behaviour Zaik.Home.Capability
  alias Zaik.Home.Capabilities.Payload

  def descriptor,
    do: %{
      id: "humidity",
      description: "Relative humidity",
      state_schema: %{"percent" => "number"},
      target_schema: nil
    }

  def detected?(device), do: Payload.present?(device, "humidity")
  def state(device), do: %{percent: Payload.numeric(device, "humidity")}
  defdelegate validate_target(target), to: Payload, as: :read_only
end

defmodule Zaik.Home.Capabilities.Illuminance do
  @moduledoc false
  @behaviour Zaik.Home.Capability
  alias Zaik.Home.Capabilities.Payload

  def descriptor,
    do: %{
      id: "illuminance",
      description: "Ambient illuminance",
      state_schema: %{"value" => "number"},
      target_schema: nil
    }

  def detected?(device), do: Payload.present?(device, "illuminance")
  def state(device), do: %{value: Payload.numeric(device, "illuminance")}
  defdelegate validate_target(target), to: Payload, as: :read_only
end

defmodule Zaik.Home.Capabilities.Presence do
  @moduledoc false
  @behaviour Zaik.Home.Capability
  alias Zaik.Home.Capabilities.Payload

  def descriptor,
    do: %{
      id: "presence",
      description: "Presence or occupancy detection",
      state_schema: %{"detected" => "boolean"},
      target_schema: nil
    }

  def detected?(device), do: Payload.present?(device, "presence")
  def state(device), do: %{detected: Payload.value(device, "presence")}
  defdelegate validate_target(target), to: Payload, as: :read_only
end

defmodule Zaik.Home.Capabilities.Cover do
  @moduledoc false
  @behaviour Zaik.Home.Capability
  alias Zaik.Home.Capabilities.Payload

  def descriptor,
    do: %{
      id: "cover",
      description: "Window covering position (0=open, 100=closed) and movement",
      state_schema: %{
        "position" => "number|null",
        "state" => "string|null",
        "adapter_state" => "string|null"
      },
      target_schema: %{
        "one_of" => [
          %{"state" => ["OPEN", "CLOSE", "STOP"]},
          %{"position" => %{"minimum" => 0, "maximum" => 100}},
          %{"preset" => "string"}
        ]
      }
    }

  def detected?(device), do: Payload.present?(device, "position")

  def state(device) do
    position = Payload.numeric(device, "position")
    reported_state = Payload.value(device, "state")

    semantic_state =
      cond do
        is_number(position) and position <= 1 -> "OPEN"
        is_number(position) and position >= 99 -> "CLOSE"
        true -> reported_state
      end

    %{position: position, state: semantic_state, adapter_state: reported_state}
  end

  def validate_target(%{"position" => position}) when is_integer(position) and position in 0..100,
    do: {:ok, %{"position" => position}}

  def validate_target(%{position: position}) when is_integer(position) and position in 0..100,
    do: {:ok, %{"position" => position}}

  def validate_target(%{"state" => "CLOSE"}), do: {:ok, %{"position" => 100}}
  def validate_target(%{state: "CLOSE"}), do: {:ok, %{"position" => 100}}
  def validate_target(%{"state" => "OPEN"}), do: {:ok, %{"position" => 0}}
  def validate_target(%{state: "OPEN"}), do: {:ok, %{"position" => 0}}
  def validate_target(%{"state" => "STOP"}), do: {:ok, %{"state" => "STOP"}}
  def validate_target(%{state: "STOP"}), do: {:ok, %{"state" => "STOP"}}

  def validate_target(%{"preset" => preset}) when is_binary(preset) and preset != "",
    do: {:ok, %{"preset" => preset}}

  def validate_target(%{preset: preset}) when is_binary(preset) and preset != "",
    do: {:ok, %{"preset" => preset}}

  def validate_target(_target), do: {:error, :invalid_cover_target}

  def capture_target(state) when is_map(state) do
    case Map.get(state, :position) || Map.get(state, "position") do
      position when is_integer(position) and position in 0..100 ->
        {:ok, %{"position" => position}}

      position when is_float(position) and position >= 0 and position <= 100 ->
        {:ok, %{"position" => round(position)}}

      _ ->
        {:error, :missing_cover_position}
    end
  end
end

defmodule Zaik.Home.Capabilities.Battery do
  @moduledoc false
  @behaviour Zaik.Home.Capability
  alias Zaik.Home.Capabilities.Payload

  def descriptor,
    do: %{
      id: "battery",
      description: "Reported battery level",
      state_schema: %{"percent" => "number"},
      target_schema: nil
    }

  def detected?(device), do: Payload.present?(device, "battery")
  def state(device), do: %{percent: Payload.numeric(device, "battery")}
  defdelegate validate_target(target), to: Payload, as: :read_only
end

defmodule Zaik.Home.Capabilities.LinkQuality do
  @moduledoc false
  @behaviour Zaik.Home.Capability
  alias Zaik.Home.Capabilities.Payload

  def descriptor,
    do: %{
      id: "linkquality",
      description: "Adapter-reported radio link quality",
      state_schema: %{"value" => "number"},
      target_schema: nil
    }

  def detected?(device), do: Payload.present?(device, "linkquality")
  def state(device), do: %{value: Payload.numeric(device, "linkquality")}
  defdelegate validate_target(target), to: Payload, as: :read_only
end

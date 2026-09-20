defmodule Zaik.Home.Entity do
  @moduledoc """
  Adapter-neutral identity and latest typed state for one home entity.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          area_id: String.t() | nil,
          aliases: [String.t()],
          source: String.t() | nil,
          capabilities: [String.t()],
          state: map(),
          observed_at: DateTime.t() | nil,
          received_at: DateTime.t() | nil,
          observation: map()
        }

  defstruct [
    :id,
    :name,
    :area_id,
    :source,
    :observed_at,
    :received_at,
    aliases: [],
    observation: %{},
    capabilities: [],
    state: %{}
  ]
end

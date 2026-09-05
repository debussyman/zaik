defmodule Zaik.Tool do
  @moduledoc """
  Runtime contract for tools exposed to an agent brain.

  Tool modules are ordinary Elixir modules. Registries discover their
  descriptors at call time rather than caching module code, so recompiling a
  module or changing the configured module list takes effect without rebuilding
  the agent loop.
  """

  @type kind :: :read | :action
  @type risk :: :none | :low | :medium | :high
  @type descriptor :: %{
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:input_schema) => map(),
          required(:kind) => kind(),
          required(:risk) => risk(),
          optional(:aliases) => [String.t()]
        }

  @callback descriptor() :: descriptor()
  @callback run(args :: map(), context :: map()) :: {:ok, term()} | {:error, term()}
end

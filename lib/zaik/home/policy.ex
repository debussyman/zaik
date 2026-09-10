defmodule Zaik.Home.Policy do
  @moduledoc """
  Contract for runtime-discovered home policies.

  Policies inspect immutable context and emit inert desired-state candidates.
  They never invoke tools, executors, or physical adapters.
  """

  @type descriptor :: %{
          required(:id) => String.t(),
          required(:version) => String.t(),
          required(:description) => String.t(),
          required(:priority) => non_neg_integer(),
          required(:dependencies) => [String.t()],
          required(:default_mode) => :off | :shadow | :advisory | :canary | :active
        }

  @callback descriptor() :: descriptor()
  @callback evaluate(context :: map(), opts :: keyword()) ::
              {:ok, [Zaik.Home.GoalCandidate.t()]} | {:error, term()}
end

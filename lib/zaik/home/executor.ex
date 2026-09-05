defmodule Zaik.Home.Executor do
  @moduledoc """
  Adapter execution contract for one typed home capability.

  Capability modules validate semantic targets. Executor modules translate a
  validated target into adapter-specific operations and return an explicit
  accepted/verified outcome.
  """

  @callback capability() :: String.t()
  @callback execute(Zaik.Home.Entity.t(), target :: map(), context :: map()) ::
              {:ok, map()} | {:error, term()}
end

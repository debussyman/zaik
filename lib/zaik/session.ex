defmodule Zaik.Session do
  @moduledoc """
  Filesystem-backed session metadata.
  """

  defstruct [
    :id,
    :path,
    :scope,
    :cwd,
    :owner,
    :current_leaf_id,
    :created_at,
    :updated_at,
    metadata: %{}
  ]
end

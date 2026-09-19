defmodule Zaik.Home.WorldContract do
  @moduledoc """
  Versioned, adapter-neutral schema contract for canonical home-world snapshots.

  The contract is rebuilt from runtime capability descriptors on every call so
  hot-loaded capabilities become visible immediately. It contains semantics and
  schemas only—never current household state or private device identity.
  """

  @schema_version 2

  def schema_version, do: @schema_version

  def descriptor(opts \\ []) do
    capability_opts = Keyword.get(opts, :capability_opts, [])

    capabilities =
      capability_opts
      |> Zaik.Home.Capabilities.Registry.modules()
      |> Enum.filter(&valid_capability?/1)
      |> Enum.map(fn module ->
        descriptor = module.descriptor()

        %{
          id: descriptor.id,
          description: descriptor.description,
          state_schema: descriptor.state_schema,
          target_schema: descriptor.target_schema,
          read_only: is_nil(descriptor.target_schema)
        }
      end)
      |> Enum.sort_by(& &1.id)

    %{
      schema_version: @schema_version,
      entity_schema: %{
        required: [
          "id",
          "name",
          "capabilities",
          "state",
          "observed_at",
          "received_at"
        ],
        optional: ["area_id", "aliases", "source"],
        timestamp_semantics: %{
          observed_at: "source observation time",
          received_at: "canonical store acceptance time"
        }
      },
      capabilities: capabilities,
      ordering: %{
        entities: "case-insensitive name ascending",
        capabilities: "capability id ascending"
      },
      observation_semantics: %{
        stale_reports: "ignored",
        duplicate_reports: "ignored",
        missing_state: "explicitly absent; never synthesized"
      },
      calibration_schema: %{
        schema_version: 1,
        scope: "entity + capability + adapter",
        authority: "inert configuration; no execution authority",
        required_audit: ["calibrated_by", "reason", "evidence"],
        supported_kinds: %{
          cover_position_linear: %{
            required: ["reported_open", "reported_closed"],
            canonical_open: 0,
            canonical_closed: 100
          }
        }
      }
    }
  end

  def fingerprint(opts \\ []) do
    opts
    |> descriptor()
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def public(opts \\ []) do
    contract = descriptor(opts)
    Map.put(contract, :fingerprint, fingerprint(opts))
  end

  defp valid_capability?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :descriptor, 0) and
      match?(:ok, Zaik.Home.Capabilities.Contract.validate(module))
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical(value), do: value
end

defmodule Zaik.Home.Policies.BedtimePrivacy do
  @moduledoc """
  Generic privacy/sleep policy driven by explicit, expiring household modes.

  Privacy closes every cover canonically. Bedtime requires a named `bedtime`
  preset for every cover, allowing installation-specific airflow positions
  without embedding device names in policy code.
  """

  @behaviour Zaik.Home.Policy

  @impl true
  def descriptor do
    %{
      id: "bedtime_privacy",
      version: "1",
      description: "Honor explicit bedtime and privacy modes for room covers.",
      priority_class: :privacy_sleep,
      priority: 80,
      dependencies: ["home_mode", "cover"],
      hysteresis: %{},
      minimum_active_seconds: 0,
      settle_seconds: 5,
      cooldown_seconds: 60,
      default_mode: :shadow
    }
  end

  @impl true
  def evaluate(context, opts \\ []) when is_map(context) do
    mode = active_mode(context)
    covers = cover_entities(context)

    cond do
      is_nil(mode) or covers == [] or manual_override?(context) ->
        {:ok, []}

      true ->
        with {:ok, desired_state, preset_evidence} <- desired_state(mode.mode, covers, context),
             {:ok, candidate} <- candidate(mode, desired_state, preset_evidence, context, opts) do
          {:ok, [candidate]}
        else
          {:error, :preset_evidence_missing} -> {:ok, []}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp desired_state("privacy", covers, _context) do
    {:ok,
     Enum.map(covers, fn entity ->
       target(entity, %{"state" => "CLOSE"})
     end), %{strategy: "canonical_closed"}}
  end

  defp desired_state("bedtime", covers, context) do
    presets = List.wrap(value(context, :device_presets))

    resolved =
      Enum.map(covers, fn entity ->
        preset =
          Enum.find(presets, fn preset ->
            normalize(Map.get(preset, "device_name")) == normalize(value(entity, :name)) and
              normalize(Map.get(preset, "preset_name")) == "bedtime" and
              normalize(Map.get(preset, "capability")) == "cover"
          end)

        if preset do
          {:ok, target(entity, Map.fetch!(preset, "target")), Map.get(preset, "preset_name")}
        else
          {:error, value(entity, :id)}
        end
      end)

    missing = for {:error, entity_id} <- resolved, do: entity_id

    if missing == [] do
      {:ok, for({:ok, desired, _name} <- resolved, do: desired),
       %{
         strategy: "named_device_presets",
         preset: "bedtime",
         entity_ids: Enum.map(covers, &value(&1, :id))
       }}
    else
      {:error, :preset_evidence_missing}
    end
  end

  defp desired_state(_mode, _covers, _context), do: {:error, :unsupported_home_mode}

  defp candidate(mode, desired_state, preset_evidence, context, opts) do
    now = Zaik.Time.now(Keyword.get(opts, :clock))
    policy = descriptor()
    mode_expires_at = parse_time(mode.expires_at)
    default_expiry = DateTime.add(now, 300, :second)

    expires_at =
      if mode_expires_at && DateTime.before?(mode_expires_at, default_expiry),
        do: mode_expires_at,
        else: default_expiry

    Zaik.Home.GoalCandidate.new(
      %{
        policy_id: policy.id,
        policy_version: policy.version,
        scope: scope(context),
        priority_class: policy.priority_class,
        priority: policy.priority,
        confidence: 1.0,
        desired_state: desired_state,
        evidence: %{
          snapshot_id: value(context, :snapshot_id),
          mode_id: mode.id,
          mode: mode.mode,
          mode_owner: mode.owner,
          mode_reason: mode.reason,
          mode_expires_at: mode.expires_at,
          target_strategy: preset_evidence
        },
        reason: "Honor active #{mode.mode} mode for room privacy and sleep.",
        created_at: now,
        expires_at: expires_at
      },
      capability_opts: Keyword.get(opts, :capability_opts, [])
    )
  end

  defp active_mode(context) do
    context
    |> value(:home_modes)
    |> List.wrap()
    |> Enum.filter(&(value(&1, :mode) in ["privacy", "bedtime"]))
    |> Enum.sort_by(fn mode ->
      {if(value(mode, :mode) == "privacy", do: 0, else: 1), value(mode, :created_at)}
    end)
    |> List.first()
  end

  defp cover_entities(context) do
    context
    |> value(:entities)
    |> List.wrap()
    |> Enum.filter(fn entity ->
      state = value(entity, :state) || %{}

      "cover" in List.wrap(value(entity, :capabilities)) or Map.has_key?(state, "cover") or
        Map.has_key?(state, :cover)
    end)
  end

  defp target(entity, target) do
    %{
      entity_id: value(entity, :id),
      device: value(entity, :name),
      capability: "cover",
      target: target
    }
  end

  defp manual_override?(context) do
    context
    |> value(:manual_overrides)
    |> List.wrap()
    |> Enum.any?(fn override ->
      capability = value(override, :capability)
      is_nil(capability) or capability == "cover"
    end)
  end

  defp scope(context), do: context |> value(:areas) |> List.wrap() |> List.first() || "home"

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_time(_value), do: nil
  defp normalize(nil), do: ""
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp value(nil, _key), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
end

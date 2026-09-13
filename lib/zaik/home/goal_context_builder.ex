defmodule Zaik.Home.GoalContextBuilder do
  @moduledoc """
  Deterministically gathers and validates the observations declared by a
  versioned goal skill before any model planning or tool execution.
  """

  def build(skill_or_goal, opts \\ []) do
    clock = Keyword.get(opts, :clock)
    now = Zaik.Time.now(clock)

    with {:ok, skill} <- resolve_skill(skill_or_goal, opts),
         {:ok, contract} <- Zaik.Home.GoalContract.new(skill),
         {:ok, room} <-
           Zaik.Home.RoomContext.build(
             String.replace(contract.scope, "_", " "),
             room_opts(opts, contract.required_observations)
           ) do
      presets = presets_for(room.entities, opts)
      evidence = evaluate_requirements(contract.required_observations, room, presets, now, opts)
      missing = Enum.filter(evidence, &(&1.status != "ok"))

      result = %{
        goal_id: contract.goal_id,
        scope: contract.scope,
        contract: contract,
        room: room,
        presets: presets,
        evidence: evidence,
        missing: missing,
        status: if(missing == [], do: "ready", else: "missing_data"),
        built_at: DateTime.to_iso8601(now),
        fingerprint:
          fingerprint(
            contract,
            evidence,
            room.occupancy,
            room.manual_overrides,
            room.home_modes,
            room.desired_state_leases
          )
      }

      missing_result(result, contract.missing_data_policy)
    end
  end

  defp resolve_skill(%{} = skill, _opts), do: {:ok, skill}

  defp resolve_skill(goal_id, opts) when is_binary(goal_id) do
    skills = Zaik.SkillStore.list(Keyword.get(opts, :skill_opts, []))

    case Enum.filter(skills, fn skill ->
           contract = skill.contract || %{}
           normalize(contract[:goal_id]) == normalize(goal_id)
         end) do
      [skill] -> {:ok, skill}
      [] -> {:error, {:goal_skill_not_found, goal_id}}
      matches -> {:error, {:ambiguous_goal_skill, Enum.map(matches, & &1.name)}}
    end
  end

  defp resolve_skill(_, _opts), do: {:error, :invalid_goal_skill}

  defp room_opts(opts, requirements) do
    history_capabilities =
      requirements
      |> Enum.flat_map(fn
        "history." <> capability -> [capability]
        _ -> []
      end)
      |> case do
        [] -> ["temperature_f", "illuminance", "presence"]
        values -> values
      end

    [
      device_store: Keyword.get(opts, :device_store),
      history_store: Keyword.get(opts, :history_store),
      occupancy_tracker: Keyword.get(opts, :occupancy_tracker),
      preset_store: Keyword.get(opts, :preset_store, Zaik.Home.DevicePresetStore),
      manual_override_store:
        Keyword.get(opts, :manual_override_store, Zaik.Home.Autonomy.ManualOverrideStore),
      mode_store: Keyword.get(opts, :mode_store, Zaik.Home.Autonomy.ModeStore),
      desired_state_store:
        Keyword.get(opts, :desired_state_store, Zaik.Home.Autonomy.DesiredStateStore),
      capability_opts: Keyword.get(opts, :capability_opts),
      clock: Keyword.get(opts, :clock),
      window_minutes: Keyword.get(opts, :window_minutes, 180),
      history_capabilities: history_capabilities,
      environment_config: Keyword.get(opts, :environment_config, %{})
    ]
  end

  defp presets_for(entities, opts) do
    store = Keyword.get(opts, :preset_store, Zaik.Home.DevicePresetStore)
    names = MapSet.new(Enum.map(entities, &normalize(&1.name)))

    if process_available?(store) do
      Zaik.Home.DevicePresetStore.list(nil, [], store)
      |> Enum.filter(&(normalize(&1["device_name"]) in names))
    else
      []
    end
  catch
    :exit, _reason -> []
  end

  defp evaluate_requirements(requirements, room, presets, now, opts) do
    Enum.map(requirements, &evaluate_requirement(&1, room, presets, now, opts))
  end

  defp evaluate_requirement("environment." <> field = requirement, room, _presets, _now, _opts) do
    value = Map.get(room.environment, String.to_existing_atom(field))
    evidence(requirement, value not in [nil, "", "unknown"], value, "environment")
  rescue
    ArgumentError -> evidence(requirement, false, nil, "environment")
  end

  defp evaluate_requirement("history." <> capability = requirement, room, _presets, _now, opts) do
    summary = Map.get(room.history, capability, %{})
    maximum_age = Keyword.get(opts, :max_history_age_seconds, 30 * 60)
    fresh? = is_integer(summary[:freshness_seconds]) and summary.freshness_seconds <= maximum_age
    evidence(requirement, summary[:status] == "ok" and fresh?, summary, "history")
  end

  defp evaluate_requirement("capability." <> capability = requirement, room, _presets, now, opts) do
    entities = Enum.filter(room.entities, &(capability in &1.capabilities))
    maximum_age = Keyword.get(opts, :max_state_age_seconds, 120)

    fresh? =
      entities != [] and
        Enum.all?(entities, fn entity ->
          case parse_time(entity.observed_at) do
            {:ok, observed_at} -> DateTime.diff(now, observed_at, :second) <= maximum_age
            _ -> false
          end
        end)

    value = Enum.map(entities, &%{entity_id: &1.id, device: &1.name, observed_at: &1.observed_at})
    evidence(requirement, fresh?, value, "canonical_state")
  end

  defp evaluate_requirement("presets." <> capability = requirement, _room, presets, _now, _opts) do
    matching = Enum.filter(presets, &(&1["capability"] == capability))
    evidence(requirement, matching != [], matching, "preset_store")
  end

  defp evaluate_requirement("occupancy" = requirement, room, _presets, _now, _opts) do
    evidence(requirement, room.occupancy.status != "unknown", room.occupancy, "occupancy")
  end

  defp evaluate_requirement(requirement, _room, _presets, _now, _opts),
    do: evidence(requirement, false, nil, "unsupported")

  defp evidence(requirement, true, value, source),
    do: %{requirement: requirement, status: "ok", source: source, value: value}

  defp evidence(requirement, false, value, source),
    do: %{requirement: requirement, status: "missing", source: source, value: value}

  defp missing_result(%{missing: []} = result, _policy), do: {:ok, result}
  defp missing_result(result, "ask"), do: {:ok, %{result | status: "needs_clarification"}}
  defp missing_result(result, "proceed_without"), do: {:ok, %{result | status: "degraded"}}

  defp missing_result(result, _policy) do
    {:error, {:missing_required_observations, Enum.map(result.missing, & &1.requirement), result}}
  end

  defp fingerprint(
         contract,
         evidence,
         occupancy,
         manual_overrides,
         home_modes,
         desired_state_leases
       ) do
    stable_evidence =
      Enum.map(evidence, fn item ->
        Map.update(item, :value, nil, &drop_derived_age/1)
      end)

    {contract, stable_evidence, occupancy, manual_overrides, home_modes, desired_state_leases}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp drop_derived_age(value) when is_map(value) do
    value
    |> Map.drop([:freshness_seconds, "freshness_seconds"])
    |> Map.new(fn {key, nested} -> {key, drop_derived_age(nested)} end)
  end

  defp drop_derived_age(value) when is_list(value), do: Enum.map(value, &drop_derived_age/1)
  defp drop_derived_age(value), do: value

  defp parse_time(%DateTime{} = value), do: {:ok, value}

  defp parse_time(value) when is_binary(value),
    do: DateTime.from_iso8601(value) |> normalize_time()

  defp parse_time(_), do: :error
  defp normalize_time({:ok, datetime, _offset}), do: {:ok, datetime}
  defp normalize_time(_), do: :error

  defp normalize(value),
    do: value |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "")

  defp process_available?(server) when is_pid(server), do: Process.alive?(server)
  defp process_available?(server) when is_atom(server), do: not is_nil(Process.whereis(server))
  defp process_available?(_server), do: false
end

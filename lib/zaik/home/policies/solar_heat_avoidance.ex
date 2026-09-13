defmodule Zaik.Home.Policies.SolarHeatAvoidance do
  @moduledoc """
  Generic thermal-comfort policy that reduces solar gain in hot, bright rooms.

  Targets come from a per-device `solar heat` cover preset. Requiring explicit
  presets keeps installation details such as cooling-airflow clearance out of
  policy code and blocks conservatively when calibration is absent.
  """

  @behaviour Zaik.Home.Policy

  @impl true
  def descriptor do
    cfg = config([])

    %{
      id: "solar_heat_avoidance",
      version: "1",
      description: "Reduce solar heat gain in sufficiently hot and bright daytime rooms.",
      priority_class: :comfort,
      priority: 60,
      dependencies: ["illuminance", "temperature", "cover", "environment"],
      hysteresis: %{
        activation_temperature_f: cfg.activation_temperature_f,
        release_temperature_f: cfg.release_temperature_f,
        activation_illuminance_lux: cfg.activation_illuminance_lux,
        release_illuminance_lux: cfg.release_illuminance_lux
      },
      minimum_active_seconds: cfg.minimum_active_seconds,
      settle_seconds: cfg.settle_seconds,
      cooldown_seconds: cfg.cooldown_seconds,
      default_mode: :shadow
    }
  end

  @impl true
  def evaluate(context, opts \\ []) when is_map(context) do
    cfg = config(opts)
    active_lease = active_lease(context)
    holding? = not is_nil(active_lease)
    temperature_f = room_temperature_f(context)
    illuminance = current_illuminance(context)

    minimum_hold? =
      holding? and lease_age_seconds(active_lease, opts) < cfg.minimum_active_seconds

    eligible? =
      solar_phase(context) == "day" and is_number(temperature_f) and is_number(illuminance) and
        not manual_override?(context) and
        if(holding?,
          do:
            (temperature_f >= cfg.release_temperature_f or minimum_hold?) and
              illuminance >= cfg.release_illuminance_lux,
          else:
            temperature_f >= cfg.activation_temperature_f and
              illuminance >= cfg.activation_illuminance_lux
        )

    if eligible? do
      with {:ok, desired_state, preset_ids} <- preset_targets(context),
           {:ok, candidate} <-
             candidate(
               context,
               desired_state,
               preset_ids,
               temperature_f,
               illuminance,
               holding?,
               minimum_hold?,
               cfg,
               opts
             ) do
        {:ok, [candidate]}
      else
        {:error, :preset_evidence_missing} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  defp candidate(
         context,
         desired_state,
         preset_ids,
         temperature_f,
         illuminance,
         holding?,
         minimum_hold?,
         cfg,
         opts
       ) do
    now = Zaik.Time.now(Keyword.get(opts, :clock))
    policy = descriptor()
    confidence = confidence(context)

    Zaik.Home.GoalCandidate.new(
      %{
        policy_id: policy.id,
        policy_version: policy.version,
        scope: scope(context),
        priority_class: policy.priority_class,
        priority: policy.priority,
        confidence: confidence,
        desired_state: desired_state,
        evidence: %{
          snapshot_id: value(context, :snapshot_id),
          temperature_f: temperature_f,
          illuminance_lux: illuminance,
          phase: if(holding?, do: "holding", else: "activation"),
          minimum_hold: minimum_hold?,
          preset: "solar heat",
          preset_entity_ids: preset_ids,
          thresholds: %{
            activation_temperature_f: cfg.activation_temperature_f,
            release_temperature_f: cfg.release_temperature_f,
            activation_illuminance_lux: cfg.activation_illuminance_lux,
            release_illuminance_lux: cfg.release_illuminance_lux,
            minimum_active_seconds: cfg.minimum_active_seconds,
            settle_seconds: cfg.settle_seconds,
            cooldown_seconds: cfg.cooldown_seconds
          }
        },
        reason: "Reduce solar gain using calibrated room cover presets.",
        created_at: now,
        expires_at: DateTime.add(now, cfg.candidate_ttl_seconds, :second)
      },
      capability_opts: Keyword.get(opts, :capability_opts, [])
    )
  end

  defp preset_targets(context) do
    covers = cover_entities(context)
    presets = List.wrap(value(context, :device_presets))

    resolved =
      Enum.map(covers, fn entity ->
        preset =
          Enum.find(presets, fn preset ->
            normalize(Map.get(preset, "device_name")) == normalize(value(entity, :name)) and
              normalize(Map.get(preset, "preset_name")) == "solar heat" and
              normalize(Map.get(preset, "capability")) == "cover"
          end)

        if preset do
          {:ok,
           %{
             entity_id: value(entity, :id),
             device: value(entity, :name),
             capability: "cover",
             target: Map.fetch!(preset, "target")
           }}
        else
          {:error, value(entity, :id)}
        end
      end)

    if covers != [] and Enum.all?(resolved, &match?({:ok, _}, &1)) do
      desired = for {:ok, target} <- resolved, do: target
      {:ok, desired, Enum.map(desired, & &1.entity_id)}
    else
      {:error, :preset_evidence_missing}
    end
  end

  defp confidence(context) do
    temperature =
      context |> value(:history) |> then(&(&1 || %{})) |> Map.get("temperature_f", %{})

    samples = value(temperature, :sample_count) || 0
    freshness = value(temperature, :freshness_seconds)

    cond do
      not is_integer(freshness) -> 0.5
      freshness > 900 -> 0.55
      samples < 2 -> 0.65
      samples < 4 -> 0.8
      true -> 0.95
    end
  end

  defp active_lease(context) do
    context
    |> value(:desired_state_leases)
    |> List.wrap()
    |> Enum.find(fn lease ->
      value(lease, :source_id) == descriptor().id and value(lease, :capability) == "cover" and
        value(lease, :status) == "active"
    end)
  end

  defp lease_age_seconds(nil, _opts), do: 0

  defp lease_age_seconds(lease, opts) do
    with created when is_binary(created) <- value(lease, :created_at),
         {:ok, created_at, _offset} <- DateTime.from_iso8601(created) do
      max(0, DateTime.diff(Zaik.Time.now(Keyword.get(opts, :clock)), created_at, :second))
    else
      _ -> 0
    end
  end

  defp current_illuminance(context) do
    context
    |> entities()
    |> Enum.flat_map(fn entity ->
      case entity |> value(:state) |> capability_state("illuminance") |> value(:value) do
        number when is_number(number) -> [number]
        _ -> []
      end
    end)
    |> case do
      [] -> nil
      values -> Enum.max(values)
    end
  end

  defp room_temperature_f(context) do
    context
    |> entities()
    |> Enum.flat_map(fn entity ->
      state = entity |> value(:state) |> capability_state("temperature")

      case value(state, :fahrenheit) do
        number when is_number(number) -> [number]
        _ -> []
      end
    end)
    |> case do
      [] -> nil
      values -> Float.round(Enum.sum(values) / length(values), 3)
    end
  end

  defp cover_entities(context) do
    context
    |> entities()
    |> Enum.filter(fn entity ->
      state = value(entity, :state) || %{}

      "cover" in List.wrap(value(entity, :capabilities)) or Map.has_key?(state, "cover") or
        Map.has_key?(state, :cover)
    end)
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

  defp config(opts) do
    configured = Application.get_env(:zaik, :home_solar_heat_policy, [])

    %{
      activation_temperature_f:
        Keyword.get(
          opts,
          :solar_heat_activation_temperature_f,
          Keyword.get(configured, :activation_temperature_f, 78.0)
        ),
      release_temperature_f:
        Keyword.get(
          opts,
          :solar_heat_release_temperature_f,
          Keyword.get(configured, :release_temperature_f, 76.0)
        ),
      activation_illuminance_lux:
        Keyword.get(
          opts,
          :solar_heat_activation_illuminance_lux,
          Keyword.get(configured, :activation_illuminance_lux, 1_000)
        ),
      release_illuminance_lux:
        Keyword.get(
          opts,
          :solar_heat_release_illuminance_lux,
          Keyword.get(configured, :release_illuminance_lux, 700)
        ),
      minimum_active_seconds: Keyword.get(configured, :minimum_active_seconds, 300),
      settle_seconds: Keyword.get(configured, :settle_seconds, 60),
      cooldown_seconds: Keyword.get(configured, :cooldown_seconds, 300),
      candidate_ttl_seconds: Keyword.get(configured, :candidate_ttl_seconds, 600)
    }
  end

  defp entities(context), do: context |> value(:entities) |> List.wrap()
  defp solar_phase(context), do: context |> value(:environment) |> value(:solar_phase)
  defp scope(context), do: context |> value(:areas) |> List.wrap() |> List.first() || "home"
  defp capability_state(nil, _capability), do: nil

  defp capability_state(state, capability) when is_map(state),
    do: Map.get(state, capability) || Map.get(state, String.to_atom(capability))

  defp normalize(nil), do: ""
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp value(nil, _key), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
end

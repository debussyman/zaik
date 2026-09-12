defmodule Zaik.Home.Policies.DaylightHarvesting do
  @moduledoc """
  Generic shadow-first policy that proposes opening closed covers when an
  occupied room is dark during daytime and cool enough for solar gain.
  """

  @behaviour Zaik.Home.Policy

  @impl true
  def descriptor do
    %{
      id: "daylight_harvesting",
      version: "1",
      description: "Prefer natural daylight in occupied, dark, sufficiently cool rooms.",
      priority: 40,
      dependencies: ["presence", "illuminance", "temperature", "cover", "environment"],
      default_mode: :shadow
    }
  end

  @impl true
  def evaluate(context, opts \\ []) when is_map(context) do
    cfg = config(opts)
    covers = closed_covers(context, cfg.closed_position_min)
    illuminance = current_numeric(context, "illuminance", :value, &Enum.max/1)
    temperature_f = room_temperature_f(context)

    eligible? =
      occupancy_status(context) == "occupied" and solar_phase(context) == "day" and
        is_number(illuminance) and illuminance <= cfg.low_light_lux and
        is_number(temperature_f) and temperature_f <= cfg.maximum_temperature_f and
        covers != [] and not manual_override?(context)

    if eligible? do
      now = Zaik.Time.now(Keyword.get(opts, :clock))
      policy = descriptor()
      confidence = confidence(context)

      desired_state =
        Enum.map(covers, fn entity ->
          %{
            entity_id: value(entity, :id),
            device: value(entity, :name),
            capability: "cover",
            target: %{"state" => "OPEN"}
          }
        end)

      Zaik.Home.GoalCandidate.new(
        %{
          policy_id: policy.id,
          policy_version: policy.version,
          scope: scope(context),
          priority: Keyword.get(opts, :priority, policy.priority),
          confidence: confidence,
          desired_state: desired_state,
          evidence: %{
            snapshot_id: value(context, :snapshot_id),
            occupancy: occupancy_status(context),
            solar_phase: solar_phase(context),
            illuminance_lux: illuminance,
            temperature_f: temperature_f,
            confidence: confidence,
            confidence_source: "minimum_of_occupancy_and_temperature_history_quality",
            closed_cover_ids: Enum.map(covers, &value(&1, :id)),
            thresholds: %{
              low_light_lux: cfg.low_light_lux,
              maximum_temperature_f: cfg.maximum_temperature_f,
              closed_position_min: cfg.closed_position_min
            }
          },
          reason: "Increase natural light before considering electric lighting.",
          created_at: now,
          expires_at: DateTime.add(now, cfg.candidate_ttl_seconds, :second)
        },
        capability_opts: Keyword.get(opts, :capability_opts, [])
      )
      |> case do
        {:ok, candidate} -> {:ok, [candidate]}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  defp confidence(context) do
    occupancy = value(context, :occupancy) || %{}
    occupancy_confidence = value(occupancy, :confidence) || 0.7
    history = value(context, :history) || %{}
    temperature = Map.get(history, "temperature_f") || Map.get(history, :temperature_f) || %{}
    samples = value(temperature, :sample_count) || 0
    freshness = value(temperature, :freshness_seconds)

    history_confidence =
      cond do
        not is_integer(freshness) -> 0.4
        freshness > 900 -> 0.5
        samples < 2 -> 0.6
        samples < 4 -> 0.8
        true -> 0.95
      end

    min(occupancy_confidence, history_confidence) |> Float.round(3)
  end

  defp config(opts) do
    configured = Application.get_env(:zaik, :daylight_harvesting, [])

    %{
      low_light_lux:
        Keyword.get(opts, :low_light_lux, Keyword.get(configured, :low_light_lux, 50)),
      maximum_temperature_f:
        Keyword.get(
          opts,
          :maximum_temperature_f,
          Keyword.get(configured, :maximum_temperature_f, 76.0)
        ),
      closed_position_min:
        Keyword.get(opts, :closed_position_min, Keyword.get(configured, :closed_position_min, 90)),
      candidate_ttl_seconds:
        Keyword.get(
          opts,
          :candidate_ttl_seconds,
          Keyword.get(configured, :candidate_ttl_seconds, 120)
        )
    }
  end

  defp closed_covers(context, minimum) do
    context
    |> entities()
    |> Enum.filter(fn entity ->
      case capability_field(entity, "cover", :position) do
        position when is_number(position) -> position >= minimum
        _ -> false
      end
    end)
  end

  defp room_temperature_f(context) do
    history = value(context, :history) || %{}
    summary = Map.get(history, "temperature_f") || Map.get(history, :temperature_f) || %{}

    case value(summary, :average) do
      value when is_number(value) -> value
      _ -> current_numeric(context, "temperature", :fahrenheit, &average/1)
    end
  end

  defp current_numeric(context, capability, field, reducer) do
    values =
      context
      |> entities()
      |> Enum.map(&capability_field(&1, capability, field))
      |> Enum.filter(&is_number/1)

    if values == [], do: nil, else: reducer.(values)
  end

  defp average(values), do: Enum.sum(values) / length(values)

  defp capability_field(entity, capability, field) do
    state = value(entity, :state) || %{}

    capability_state =
      Map.get(state, capability) || Map.get(state, String.to_atom(capability)) || %{}

    value(capability_state, field)
  end

  defp entities(context), do: List.wrap(value(context, :entities))

  defp occupancy_status(context) do
    context |> value(:occupancy) |> then(&value(&1 || %{}, :status))
  end

  defp solar_phase(context) do
    context |> value(:environment) |> then(&value(&1 || %{}, :solar_phase))
  end

  defp manual_override?(context) do
    case value(context, :manual_override) do
      nil -> false
      false -> false
      [] -> false
      [_ | _] -> true
      %{} = override -> value(override, :active) != false
      _ -> true
    end
  end

  defp scope(context) do
    case List.wrap(value(context, :areas)) do
      [area | _] -> to_string(area)
      _ -> to_string(value(context, :query) || "home")
    end
  end

  defp value(nil, _key), do: nil
  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
end

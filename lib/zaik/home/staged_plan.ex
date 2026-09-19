defmodule Zaik.Home.StagedPlan do
  @moduledoc """
  Inert, fully preflighted contract for future conditional home plans.

  This module does not execute, sleep, schedule timers, or invoke adapters. It
  validates every stage action through `Zaik.Home.ActionPlan` and every
  condition through the typed condition boundary before a staged workflow can
  be persisted or executed by a future supervised coordinator.
  """

  alias Zaik.Home.ActionPlan.Condition

  @default_max_stages 5
  @default_max_actions 10
  @maximum_deadline_seconds 24 * 60 * 60
  @maximum_wait_seconds 60 * 60
  @maximum_poll_seconds 60

  @enforce_keys [:id, :goal, :stages, :prepared_at, :expires_at, :status]
  defstruct @enforce_keys

  @type stage :: %{
          id: binary(),
          index: non_neg_integer(),
          conditions: [Condition.t()],
          condition_mode: binary(),
          wait: map() | nil,
          on_condition_false: binary(),
          action_plan: Zaik.Home.ActionPlan.t()
        }

  @type t :: %__MODULE__{
          id: binary(),
          goal: binary() | nil,
          stages: [stage()],
          prepared_at: DateTime.t(),
          expires_at: DateTime.t(),
          status: binary()
        }

  def preflight(goal, stages, context \\ %{}, opts \\ [])

  def preflight(goal, stages, context, opts)
      when is_list(stages) and is_map(context) and is_list(opts) do
    max_stages = Keyword.get(opts, :max_stages, @default_max_stages)
    max_actions = Keyword.get(opts, :max_actions, configured_max_actions())
    deadline_seconds = Keyword.get(opts, :deadline_seconds, 15 * 60)

    with :ok <- validate_stage_count(stages, max_stages),
         {:ok, deadline_seconds} <- validate_deadline(deadline_seconds),
         {:ok, prepared} <- prepare_stages(goal, stages, context, opts),
         :ok <- validate_total_actions(prepared, max_actions),
         :ok <- validate_unique_stage_ids(prepared) do
      prepared_at = Zaik.Time.now(value(context, :clock))
      expires_at = DateTime.add(prepared_at, deadline_seconds, :second)
      normalized_goal = normalize_goal(goal)

      attrs = %{
        goal: normalized_goal,
        stages: prepared,
        prepared_at: prepared_at,
        expires_at: expires_at,
        status: "prepared"
      }

      {:ok, struct!(__MODULE__, Map.put(attrs, :id, plan_id(attrs)))}
    end
  end

  def preflight(_goal, _stages, _context, _opts),
    do: {:error, {:invalid_staged_plan, [%{stage: nil, reason: :stages_must_be_a_list}]}}

  def public(%__MODULE__{} = plan) do
    %{
      id: plan.id,
      goal: plan.goal,
      status: plan.status,
      prepared_at: DateTime.to_iso8601(plan.prepared_at),
      expires_at: DateTime.to_iso8601(plan.expires_at),
      stages: Enum.map(plan.stages, &public_stage/1)
    }
  end

  defp prepare_stages(goal, stages, context, opts) do
    results =
      stages
      |> Enum.with_index()
      |> Enum.map(fn {stage, index} -> prepare_stage(goal, stage, index, context, opts) end)

    errors = for {:error, error} <- results, do: error

    if errors == [] do
      {:ok, for({:ok, stage} <- results, do: stage)}
    else
      {:error, {:invalid_staged_plan, errors}}
    end
  end

  defp prepare_stage(goal, stage, index, context, opts) when is_map(stage) do
    stage_id = normalize(value(stage, :id) || "stage-#{index + 1}")
    conditions = value(stage, :conditions) || []
    condition_mode = normalize(value(stage, :condition_mode) || "all")
    on_false = normalize(value(stage, :on_condition_false) || "cancel_plan")
    actions = value(stage, :actions)
    wait = value(stage, :wait)

    with :ok <- validate_stage_id(stage_id),
         :ok <- validate_condition_mode(condition_mode),
         :ok <- validate_on_false(on_false),
         {:ok, conditions} <- prepare_conditions(conditions, index, context, opts),
         {:ok, wait} <- validate_wait(wait, conditions),
         {:ok, action_plan} <-
           Zaik.Home.ActionPlan.preflight(
             stage_goal(goal, stage_id),
             actions,
             context,
             Keyword.take(opts, [:max_actions, :capability_opts, :executor_opts])
           ) do
      {:ok,
       %{
         id: stage_id,
         index: index,
         conditions: conditions,
         condition_mode: condition_mode,
         wait: wait,
         on_condition_false: on_false,
         action_plan: action_plan
       }}
    else
      {:error, {:invalid_action_plan, reasons}} ->
        {:error, %{stage: index, stage_id: stage_id, reason: {:invalid_actions, reasons}}}

      {:error, reason} ->
        {:error, %{stage: index, stage_id: stage_id, reason: reason}}
    end
  end

  defp prepare_stage(_goal, _stage, index, _context, _opts),
    do: {:error, %{stage: index, stage_id: nil, reason: :stage_must_be_an_object}}

  defp prepare_conditions(conditions, _stage_index, _context, _opts)
       when not is_list(conditions),
       do: {:error, :conditions_must_be_a_list}

  defp prepare_conditions(conditions, stage_index, context, opts) do
    results =
      conditions
      |> Enum.with_index()
      |> Enum.map(fn {condition, index} ->
        case Condition.preflight(condition, context, opts) do
          {:ok, prepared} -> {:ok, prepared}
          {:error, reason} -> {:error, %{stage: stage_index, condition: index, reason: reason}}
        end
      end)

    case for({:error, error} <- results, do: error) do
      [] -> {:ok, for({:ok, condition} <- results, do: condition)}
      errors -> {:error, {:invalid_conditions, errors}}
    end
  end

  defp validate_wait(nil, _conditions), do: {:ok, nil}
  defp validate_wait(_wait, []), do: {:error, :wait_requires_conditions}

  defp validate_wait(wait, _conditions) when is_map(wait) do
    timeout = value(wait, :timeout_seconds)
    poll = value(wait, :poll_interval_seconds) || 1

    cond do
      not is_integer(timeout) or timeout < 1 or timeout > @maximum_wait_seconds ->
        {:error, {:invalid_wait_timeout_seconds, timeout}}

      not is_integer(poll) or poll < 1 or poll > @maximum_poll_seconds or poll > timeout ->
        {:error, {:invalid_wait_poll_interval_seconds, poll}}

      true ->
        {:ok, %{timeout_seconds: timeout, poll_interval_seconds: poll}}
    end
  end

  defp validate_wait(_wait, _conditions), do: {:error, :wait_must_be_an_object}

  defp validate_stage_count([], _maximum),
    do: {:error, {:invalid_staged_plan, [%{stage: nil, reason: :empty_plan}]}}

  defp validate_stage_count(stages, maximum)
       when is_integer(maximum) and maximum > 0 and length(stages) <= maximum,
       do: :ok

  defp validate_stage_count(stages, maximum),
    do:
      {:error,
       {:invalid_staged_plan,
        [%{stage: nil, reason: {:too_many_stages, length(stages), maximum}}]}}

  defp validate_deadline(value)
       when is_integer(value) and value >= 1 and value <= @maximum_deadline_seconds,
       do: {:ok, value}

  defp validate_deadline(value), do: {:error, {:invalid_staged_plan_deadline_seconds, value}}

  defp validate_total_actions(stages, maximum) do
    count =
      Enum.reduce(stages, 0, fn stage, total -> total + length(stage.action_plan.actions) end)

    if is_integer(maximum) and maximum > 0 and count <= maximum,
      do: :ok,
      else: {:error, {:too_many_staged_actions, count, maximum}}
  end

  defp validate_unique_stage_ids(stages) do
    ids = Enum.map(stages, & &1.id)
    if length(ids) == length(Enum.uniq(ids)), do: :ok, else: {:error, :duplicate_stage_id}
  end

  defp validate_stage_id(""), do: {:error, :missing_stage_id}
  defp validate_stage_id(_id), do: :ok
  defp validate_condition_mode(mode) when mode in ["all", "any"], do: :ok
  defp validate_condition_mode(mode), do: {:error, {:unsupported_condition_mode, mode}}
  defp validate_on_false("cancel_plan"), do: :ok
  defp validate_on_false(value), do: {:error, {:unsupported_condition_false_behavior, value}}

  defp public_stage(stage) do
    %{
      id: stage.id,
      index: stage.index,
      conditions: Enum.map(stage.conditions, &Condition.public/1),
      condition_mode: stage.condition_mode,
      wait: stage.wait,
      on_condition_false: stage.on_condition_false,
      action_plan_id: stage.action_plan.id,
      actions:
        Enum.map(stage.action_plan.actions, fn action ->
          %{
            index: action.index,
            entity_id: action.entity.id,
            device: action.entity.name,
            capability: action.capability,
            target: action.target
          }
        end)
    }
  end

  defp plan_id(attrs) do
    canonical = %{
      goal: attrs.goal,
      expires_at: DateTime.to_iso8601(attrs.expires_at),
      stages: Enum.map(attrs.stages, &public_stage/1)
    }

    canonical
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  defp configured_max_actions do
    Application.get_env(:zaik, :home_action_plans, [])
    |> Keyword.get(:max_actions, @default_max_actions)
  end

  defp stage_goal(goal, stage_id), do: "#{normalize_goal(goal) || "staged plan"} / #{stage_id}"
  defp normalize_goal(nil), do: nil
  defp normalize_goal(goal), do: goal |> to_string() |> String.trim()
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

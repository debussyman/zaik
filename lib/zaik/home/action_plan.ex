defmodule Zaik.Home.ActionPlan do
  @moduledoc """
  Preflighted multi-action home plan.

  Every entity, capability, target, preset, and executor is resolved before the
  first side effect. Execution is sequential and returns a structured partial
  report if a later action fails. `Zaik.Tools.Executor` supervises and
  idempotently wraps the complete plan tool call.
  """

  @default_max_actions 10

  @type prepared_action :: %{
          required(:index) => non_neg_integer(),
          required(:entity) => Zaik.Home.Entity.t(),
          required(:capability) => String.t(),
          required(:requested_target) => map(),
          required(:target) => map()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          goal: String.t() | nil,
          actions: [prepared_action()],
          prepared_at: DateTime.t()
        }

  defstruct [:id, :goal, :prepared_at, actions: []]

  def run(goal, actions, context \\ %{}, opts \\ []) do
    with {:ok, plan} <- preflight(goal, actions, context, opts) do
      execute(plan, context, opts)
    end
  end

  def preflight(goal, actions, context \\ %{}, opts \\ [])

  def preflight(goal, actions, context, opts) when is_list(actions) and is_map(context) do
    max_actions =
      Keyword.get(opts, :max_actions) ||
        Application.get_env(:zaik, :home_action_plans, [])
        |> Keyword.get(:max_actions, @default_max_actions)

    cond do
      actions == [] ->
        {:error, {:invalid_action_plan, [%{index: nil, reason: :empty_plan}]}}

      length(actions) > max_actions ->
        {:error,
         {:invalid_action_plan,
          [%{index: nil, reason: {:too_many_actions, length(actions), max_actions}}]}}

      true ->
        prepare_actions(goal, actions, context, opts)
    end
  end

  def preflight(_goal, _actions, _context, _opts),
    do: {:error, {:invalid_action_plan, [%{index: nil, reason: :actions_must_be_a_list}]}}

  def execute(%__MODULE__{} = plan, context \\ %{}, opts \\ []) do
    executor_opts =
      Keyword.get(opts, :executor_opts) || value(context, :executor_opts) || []

    run_id = value(context, :action_id) || Zaik.Home.ActionVerifier.new_id("plan")
    context = Map.put(context, :plan_run_id, run_id)

    execute_actions(plan, plan.actions, [], context, executor_opts)
  end

  defp prepare_actions(goal, actions, context, opts) do
    prepared =
      actions
      |> Enum.with_index()
      |> Enum.map(fn {action, index} ->
        case prepare_action(action, index, context, opts) do
          {:ok, prepared_action} -> {:ok, prepared_action}
          {:error, reason} -> {:error, %{index: index, reason: reason}}
        end
      end)

    errors = for {:error, error} <- prepared, do: error
    valid_actions = for {:ok, action} <- prepared, do: action
    duplicate_errors = duplicate_errors(valid_actions)
    errors = errors ++ duplicate_errors

    if errors == [] do
      prepared_at = DateTime.utc_now()

      {:ok,
       %__MODULE__{
         id: plan_id(goal, valid_actions),
         goal: normalize_goal(goal),
         actions: valid_actions,
         prepared_at: prepared_at
       }}
    else
      {:error, {:invalid_action_plan, errors}}
    end
  end

  defp prepare_action(action, index, context, opts) when is_map(action) do
    device = value(action, :device) || value(action, :entity_id)
    capability = value(action, :capability)
    requested_target = value(action, :target)

    capability_opts =
      Keyword.get(opts, :capability_opts) || value(context, :capability_opts) || []

    executor_opts =
      Keyword.get(opts, :executor_opts) || value(context, :executor_opts) || []

    world_opts =
      []
      |> put_if(:device_store, value(context, :device_store))
      |> put_if(:capability, capability)
      |> put_if(:capability_opts, capability_opts)

    with {:ok, device} <- non_empty(device, :missing_device),
         {:ok, capability} <- non_empty(capability, :missing_capability),
         {:ok, requested_target} <- target_map(requested_target),
         {:ok, entity} <- Zaik.Home.World.get(device, world_opts),
         {:ok, capability_module} <-
           Zaik.Home.Capabilities.Registry.fetch(capability, capability_opts),
         {:ok, validated_target} <- capability_module.validate_target(requested_target),
         {:ok, _executor} <- Zaik.Home.Executors.Registry.fetch(capability, executor_opts),
         {:ok, prepared_target} <-
           Zaik.Home.Executors.Registry.prepare(
             capability,
             entity,
             validated_target,
             context,
             executor_opts
           ),
         {:ok, prepared_target} <- capability_module.validate_target(prepared_target) do
      {:ok,
       %{
         index: index,
         entity: entity,
         capability: capability,
         requested_target: requested_target,
         target: prepared_target
       }}
    end
  end

  defp prepare_action(_action, _index, _context, _opts), do: {:error, :action_must_be_an_object}

  defp execute_actions(plan, [], completed, context, _executor_opts) do
    results = completed |> Enum.reverse() |> finalize_verifications(context)
    verified? = Enum.all?(results, &result_verified?/1)

    {:ok,
     %{
       plan_id: plan.id,
       plan_run_id: value(context, :plan_run_id),
       goal: plan.goal,
       status: if(verified?, do: "verified", else: "accepted"),
       verified: verified?,
       verification_ids: verification_ids(results),
       completed_count: length(results),
       action_count: length(plan.actions),
       actions: results,
       completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  defp execute_actions(plan, [action | remaining], completed, context, executor_opts) do
    action_context =
      context
      |> Map.put(:action_id, child_action_id(context, plan, action))
      |> Map.put(:defer_verification_wait, true)

    case Zaik.Home.Executors.Registry.execute(
           action.capability,
           action.entity,
           action.target,
           action_context,
           executor_opts
         ) do
      {:ok, result} ->
        completed_action = %{
          action: public_action(action),
          result: result
        }

        execute_actions(plan, remaining, [completed_action | completed], context, executor_opts)

      {:error, reason} ->
        fail_plan(plan, action, remaining, completed, reason)

      other ->
        fail_plan(plan, action, remaining, completed, {:invalid_executor_result, other})
    end
  end

  defp fail_plan(plan, action, remaining, completed, reason) do
    completed = Enum.reverse(completed)

    report = %{
      plan_id: plan.id,
      goal: plan.goal,
      status: if(completed == [], do: "failed", else: "partially_completed"),
      verified: false,
      completed_count: length(completed),
      action_count: length(plan.actions),
      completed: completed,
      failed: %{action: public_action(action), reason: inspect(reason)},
      remaining: Enum.map(remaining, &public_action/1),
      failed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:error, {:action_plan_failed, report}}
  end

  defp public_action(action) do
    %{
      index: action.index,
      entity_id: action.entity.id,
      device: action.entity.name,
      capability: action.capability,
      requested_target: action.requested_target,
      target: action.target
    }
  end

  defp duplicate_errors(actions) do
    actions
    |> Enum.group_by(&{&1.entity.id, &1.capability, canonical(&1.target)})
    |> Enum.flat_map(fn
      {_key, [_single]} ->
        []

      {_key, duplicates} ->
        [%{index: Enum.map(duplicates, & &1.index), reason: :duplicate_action}]
    end)
  end

  defp finalize_verifications(results, context) do
    ids = verification_ids(results)
    server = value(context, :action_verifier) || Zaik.Home.ActionVerifier
    wait_ms = value(context, :verification_wait_ms) || Zaik.Home.ActionVerifier.config().wait_ms

    if ids == [] or not process_available?(server) do
      results
    else
      statuses = Zaik.Home.ActionVerifier.await_many(ids, wait_ms, server: server)

      Enum.map(results, fn completed ->
        action_id = result_action_id(completed)

        case Map.get(statuses, action_id) do
          %{verified: true} = verification ->
            result =
              completed.result
              |> Map.put(:status, "verified")
              |> Map.put(:verified, true)
              |> Map.put(:verification_status, "verified")
              |> Map.put(:observed_at, verification.observed_at)
              |> Map.put(:observed, verification.observed)

            %{completed | result: result}

          _ ->
            completed
        end
      end)
    end
  catch
    :exit, _reason -> results
  end

  defp verification_ids(results) do
    results
    |> Enum.map(&result_action_id/1)
    |> Enum.reject(&is_nil/1)
  end

  defp result_action_id(%{result: result}) when is_map(result),
    do: Map.get(result, :action_id) || Map.get(result, "action_id")

  defp result_action_id(_result), do: nil

  defp child_action_id(context, plan, action) do
    "#{value(context, :plan_run_id)}:#{plan.id}:#{action.index}"
  end

  defp process_available?(server) when is_pid(server), do: Process.alive?(server)
  defp process_available?(server) when is_atom(server), do: not is_nil(Process.whereis(server))
  defp process_available?(_server), do: false

  defp result_verified?(%{result: result}) when is_map(result) do
    Map.get(result, :verified) == true or Map.get(result, "verified") == true
  end

  defp result_verified?(_result), do: false

  defp plan_id(goal, actions) do
    public = Enum.map(actions, &public_action/1)

    :crypto.hash(:sha256, :erlang.term_to_binary({normalize_goal(goal), canonical(public)}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  defp normalize_goal(nil), do: nil
  defp normalize_goal(goal), do: goal |> to_string() |> String.trim()

  defp target_map(target) when is_map(target), do: {:ok, target}
  defp target_map(_target), do: {:error, :missing_target}

  defp non_empty(nil, error), do: {:error, error}

  defp non_empty(value, error) do
    value = value |> to_string() |> String.trim()
    if value == "", do: {:error, error}, else: {:ok, value}
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

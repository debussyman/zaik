defmodule Zaik.Tools.Executor do
  @moduledoc """
  Supervised execution boundary for registered tools.

  Reads run directly. Actions are claimed in the persistent action ledger and
  run under a `Task.Supervisor` with a bounded timeout. This keeps model fallback
  and duplicate ingress delivery from replaying the same semantic action.
  """

  @default_action_timeout_ms 30_000

  def run(tool, args, context \\ %{}, opts \\ []) do
    registry_opts = Keyword.get(opts, :registry_opts, [])

    with {:ok, %{descriptor: descriptor}} <- Zaik.Tools.Registry.fetch(tool, registry_opts),
         :ok <- authorize_active_skills(descriptor, context) do
      if descriptor.kind == :action do
        run_action(
          descriptor.name,
          args,
          context,
          fn action_context ->
            Zaik.Tools.Registry.run(descriptor.name, args, action_context, registry_opts)
          end,
          opts
        )
      else
        Zaik.Tools.Registry.run(descriptor.name, args, context, registry_opts)
      end
    end
  end

  def run_action(tool, args, context, fun, opts \\ [])
      when is_function(fun, 0) or is_function(fun, 1) do
    ledger = option_or_context(opts, :ledger, context, :action_ledger, Zaik.Home.ActionLedger)

    opts =
      Keyword.put_new_lazy(opts, :task_supervisor, fn ->
        context_value(context, :task_supervisor) || Zaik.Tools.TaskSupervisor
      end)

    case claim(ledger, tool, args, context) do
      {:duplicate, result} ->
        result

      {:ok, key} ->
        action_id = key || Zaik.Home.ActionVerifier.new_id()

        action_context =
          context
          |> Map.put(:action_id, action_id)
          |> Map.put(:ledger_action_id, key)
          |> Map.put(:action_ledger, ledger)

        result = execute_supervised(fn -> invoke(fun, action_context) end, opts)
        complete(ledger, key, result)
        result

      {:error, reason} ->
        {:error, {:action_claim_failed, reason}}
    end
  end

  defp authorize_active_skills(%{kind: kind}, _context) when kind != :action, do: :ok

  defp authorize_active_skills(descriptor, context) do
    skills = List.wrap(context_value(context, :active_skills))

    Enum.reduce_while(skills, :ok, fn skill, :ok ->
      allowed_tools = Map.get(skill, :allowed_tools) || Map.get(skill, "allowed_tools") || []
      declared_risk = Map.get(skill, :risk) || Map.get(skill, "risk")

      cond do
        not skill_allows_tool?(descriptor.name, allowed_tools) ->
          {:halt,
           {:error,
            {:skill_tool_not_allowed, Map.get(skill, :name) || Map.get(skill, "name"),
             descriptor.name}}}

        risk_rank(declared_risk) < risk_rank(descriptor.risk) ->
          {:halt,
           {:error,
            {:skill_risk_exceeded, Map.get(skill, :name) || Map.get(skill, "name"), declared_risk,
             descriptor.risk}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp skill_allows_tool?(tool, allowed_tools) do
    allowed = Enum.map(allowed_tools, &normalize_tool_name/1)

    tool in allowed or (tool == "control_blind" and "control_device" in allowed)
  end

  defp normalize_tool_name(name), do: name |> to_string() |> String.trim() |> String.downcase()
  defp risk_rank(value) when value in [:none, "none"], do: 0
  defp risk_rank(value) when value in [:low, "low"], do: 1
  defp risk_rank(value) when value in [:medium, "medium"], do: 2
  defp risk_rank(value) when value in [:high, "high"], do: 3
  defp risk_rank(_value), do: -1

  defp invoke(fun, _context) when is_function(fun, 0), do: fun.()
  defp invoke(fun, context) when is_function(fun, 1), do: fun.(context)

  defp execute_supervised(fun, opts) do
    timeout_ms =
      Keyword.get(opts, :timeout_ms) ||
        Application.get_env(:zaik, :tool_execution, [])
        |> Keyword.get(:action_timeout_ms, @default_action_timeout_ms)

    supervisor = Keyword.get(opts, :task_supervisor, Zaik.Tools.TaskSupervisor)

    if supervisor_available?(supervisor) do
      task = Task.Supervisor.async_nolink(supervisor, fun)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:action_task_exit, reason}}
        nil -> {:error, :action_timeout}
      end
    else
      safe_call(fun)
    end
  end

  defp safe_call(fun) do
    fun.()
  rescue
    error -> {:error, {:action_exception, error}}
  catch
    :exit, reason -> {:error, {:action_exit, reason}}
  end

  defp claim(nil, _tool, _args, _context), do: {:ok, nil}

  defp claim(ledger, tool, args, context) when is_pid(ledger) do
    if Process.alive?(ledger),
      do: Zaik.Home.ActionLedger.claim(tool, args, context, ledger),
      else: {:ok, nil}
  catch
    :exit, reason -> {:error, reason}
  end

  defp claim(ledger, tool, args, context) do
    if process_available?(ledger),
      do: ledger.claim(tool, args, context),
      else: {:ok, nil}
  catch
    :exit, reason -> {:error, reason}
  end

  defp complete(_ledger, nil, _result), do: :ok

  defp complete(ledger, key, result) when is_pid(ledger) do
    Zaik.Home.ActionLedger.complete(key, result, ledger)
  catch
    :exit, _reason -> :ok
  end

  defp complete(ledger, key, result) do
    ledger.complete(key, result)
  catch
    :exit, _reason -> :ok
  end

  defp supervisor_available?(supervisor) when is_atom(supervisor),
    do: not is_nil(Process.whereis(supervisor))

  defp supervisor_available?(supervisor) when is_pid(supervisor), do: Process.alive?(supervisor)
  defp supervisor_available?(_supervisor), do: false

  defp option_or_context(opts, option, context, context_key, default) do
    if Keyword.has_key?(opts, option) do
      Keyword.fetch!(opts, option)
    else
      case Map.fetch(context, context_key) do
        {:ok, value} -> value
        :error -> Map.get(context, to_string(context_key), default)
      end
    end
  end

  defp context_value(context, key), do: Map.get(context, key) || Map.get(context, to_string(key))

  defp process_available?(ledger) when is_atom(ledger), do: not is_nil(Process.whereis(ledger))
  defp process_available?(ledger) when is_pid(ledger), do: Process.alive?(ledger)
  defp process_available?(_ledger), do: false
end

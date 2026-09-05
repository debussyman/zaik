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

    with {:ok, %{descriptor: descriptor}} <- Zaik.Tools.Registry.fetch(tool, registry_opts) do
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
    ledger = Keyword.get(opts, :ledger, Zaik.Home.ActionLedger)

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

  defp process_available?(ledger) when is_atom(ledger), do: not is_nil(Process.whereis(ledger))
  defp process_available?(ledger) when is_pid(ledger), do: Process.alive?(ledger)
  defp process_available?(_ledger), do: false
end

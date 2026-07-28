defmodule Zaik.Agent.TaskRunner do
  @moduledoc """
  Behaviour for one-shot task agents.
  """

  @callback agent_init(task :: Zaik.Task.t(), opts :: keyword()) ::
              {:ok, state :: term()} | {:error, reason :: term()}

  @callback run_task(task :: Zaik.Task.t(), state :: term()) ::
              {:ok, result :: term(), new_state :: term()}
              | {:error, reason :: term(), new_state :: term()}

  @optional_callbacks agent_init: 2

  defmacro __using__(_opts) do
    quote do
      use GenServer

      @behaviour Zaik.Agent.TaskRunner

      def start_link(opts) do
        {server_opts, init_opts} = Keyword.split(opts, [:name])
        GenServer.start_link(__MODULE__, init_opts, server_opts)
      end

      @impl GenServer
      def init(opts) do
        task = Keyword.fetch!(opts, :task)
        dispatcher = Keyword.fetch!(opts, :dispatcher)

        with {:ok, agent_state} <- agent_init(task, opts) do
          Process.send_after(self(), :run_task, 0)
          {:ok, %{task: task, dispatcher: dispatcher, agent_state: agent_state}}
        end
      end

      @impl GenServer
      def handle_info(
            :run_task,
            %{task: task, dispatcher: dispatcher, agent_state: agent_state} = state
          ) do
        case apply(__MODULE__, :run_task, [task, agent_state]) do
          {:ok, result, new_agent_state} ->
            send(dispatcher, {:task_complete, task.id, result})
            {:stop, :normal, %{state | agent_state: new_agent_state}}

          {:error, reason, new_agent_state} ->
            send(dispatcher, {:task_failed, task.id, reason})
            {:stop, :normal, %{state | agent_state: new_agent_state}}

          invalid ->
            send(dispatcher, {:task_failed, task.id, {:invalid_agent_result, invalid}})
            {:stop, :normal, state}
        end
      rescue
        exception ->
          reason = {exception.__struct__, Exception.message(exception), __STACKTRACE__}
          send(dispatcher, {:task_failed, task.id, reason})
          {:stop, {:shutdown, reason}, state}
      end

      def agent_init(_task, _opts), do: {:ok, %{}}

      defoverridable agent_init: 2
    end
  end
end

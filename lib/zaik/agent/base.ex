defmodule Zaik.Agent.Base do
  @moduledoc """
  Base behavior for Zaik agents.

  `use Zaik.Agent.Base` turns a module into a small GenServer-backed agent
  with overridable callbacks for initialization, incoming messages, and ticks.
  """

  @callback agent_init(args :: term()) :: {:ok, state :: term()} | {:error, reason :: term()}
  @callback handle_message(message :: term(), state :: term()) ::
              {:reply, reply :: term(), new_state :: term()} | {:noreply, new_state :: term()}
  @callback handle_tick(state :: term()) :: new_state :: term()

  @optional_callbacks agent_init: 1, handle_message: 2, handle_tick: 1

  defmacro __using__(_opts) do
    quote do
      use GenServer

      @behaviour Zaik.Agent.Base

      def start_link(opts \\ []) do
        {server_opts, init_opts} = Keyword.split(opts, [:name])
        {init_arg, _init_opts} = Keyword.pop(init_opts, :init_arg, [])

        GenServer.start_link(__MODULE__, init_arg, server_opts)
      end

      def send_message(server, message) do
        GenServer.call(server, {:message, message})
      end

      def tick(server) do
        GenServer.cast(server, :tick)
      end

      @impl GenServer
      def init(args) do
        agent_init(args)
      end

      @impl GenServer
      def handle_call({:message, message}, _from, state) do
        case handle_message(message, state) do
          {:reply, reply, new_state} -> {:reply, reply, new_state}
          {:noreply, new_state} -> {:reply, :ok, new_state}
        end
      end

      @impl GenServer
      def handle_cast(:tick, state) do
        {:noreply, handle_tick(state)}
      end

      def agent_init(args) do
        {:ok, args}
      end

      def handle_message(_message, state) do
        {:noreply, state}
      end

      def handle_tick(state) do
        state
      end

      defoverridable agent_init: 1, handle_message: 2, handle_tick: 1
    end
  end
end

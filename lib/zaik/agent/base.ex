defmodule Zaik.Agent.Base do
  @moduledoc """
  Base behavior for all agents in the Zaik system.
  """

  @callback init(args :: term()) :: {:ok, state :: term()} | {:error, reason :: term()}
  @callback handle_message(message :: term(), state :: term()) :: {:reply, reply :: term(), new_state :: term()} | {:noreply, new_state :: term()}
  @callback handle_tick(state :: term()) :: new_state :: term()
  @callback handle_info(info :: term(), state :: term()) :: {:noreply, new_state :: term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Zaik.Agent.Base

      def start_link(args) do
        Agent.start_link(&__MODULE__.init/1, args)
      end

      def send_message(agent_pid, message) do
        Agent.cast(agent_pid, fn state ->
          case __MODULE__.handle_message(message, state) do
            {:reply, reply, new_state} ->
              # Handle reply if needed
              new_state
            {:noreply, new_state} ->
              new_state
          end
        end)
      end

      def handle_info(_info, state) do
        {:noreply, state}
      end

      defoverridable handle_info: 2
    end
  end
end
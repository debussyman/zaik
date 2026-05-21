defmodule Zaik.Agent.HelloWorld do
  @moduledoc """
  A simple hello world agent to serve as the example agent in our system.
  """

  use GenServer

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def hello() do
    GenServer.call(__MODULE__, :hello)
  end

  def send_message(message) do
    GenServer.cast(__MODULE__, {:message, message})
  end

  # Server Callbacks

  def init(_opts) do
    # Initialize agent with empty state
    state = %{
      name: "HelloWorldAgent",
      messages: [],
      last_seen: nil
    }
    {:ok, state}
  end

  def handle_call(:hello, _from, state) do
    {:reply, "Hello from #{state.name}!", state}
  end

  def handle_cast({:message, message}, state) do
    # Add message to the history
    updated_messages = [message | state.messages]
    new_state = %{state | messages: updated_messages, last_seen: DateTime.utc_now()}
    {:noreply, new_state}
  end

  def handle_info(:tick, state) do
    # Handle periodic ticks
    IO.puts("Tick from #{state.name}")
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
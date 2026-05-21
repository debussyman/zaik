defmodule Zaik.Agent.HelloWorld do
  @moduledoc """
  A simple hello world agent to serve as the first example agent in Zaik.
  """

  use GenServer

  # Client API

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def hello(server \\ __MODULE__) do
    GenServer.call(server, :hello)
  end

  def send_message(message) do
    send_message(__MODULE__, message)
  end

  def send_message(server, message) do
    GenServer.cast(server, {:message, message})
  end

  def state(server \\ __MODULE__) do
    GenServer.call(server, :state)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    state = %{
      name: Keyword.get(opts, :agent_name, "HelloWorldAgent"),
      messages: [],
      last_seen: nil,
      ticks: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:hello, _from, state) do
    {:reply, "Hello from #{state.name}!", state}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:message, message}, state) do
    new_state = %{
      state
      | messages: [message | state.messages],
        last_seen: DateTime.utc_now()
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:tick, state) do
    {:noreply, %{state | ticks: state.ticks + 1}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end

defmodule Zaik.Agent.BaseTest do
  use ExUnit.Case, async: true

  defmodule EchoAgent do
    use Zaik.Agent.Base

    @impl true
    def agent_init(_args), do: {:ok, %{messages: [], ticks: 0}}

    @impl true
    def handle_message(:record_only, state) do
      {:noreply, %{state | messages: [:record_only | state.messages]}}
    end

    def handle_message(message, state) do
      new_state = %{state | messages: [message | state.messages]}
      {:reply, {:echo, message}, new_state}
    end

    @impl true
    def handle_tick(state) do
      %{state | ticks: state.ticks + 1}
    end
  end

  describe "Base agent" do
    test "injects a GenServer-backed agent API" do
      name = unique_name()
      pid = start_supervised!({EchoAgent, name: name})

      assert Process.alive?(pid)
      assert EchoAgent.send_message(name, "hello") == {:echo, "hello"}
    end

    test "supports tick callbacks" do
      name = unique_name()
      pid = start_supervised!({EchoAgent, name: name})

      assert :ok = EchoAgent.tick(name)
      assert eventually(fn -> :sys.get_state(pid).ticks == 1 end)
    end
  end

  defp unique_name do
    String.to_atom("echo_agent_#{System.unique_integer([:positive])}")
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end
end

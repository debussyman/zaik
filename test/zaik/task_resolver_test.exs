defmodule Zaik.TaskResolverTest do
  use ExUnit.Case, async: false

  defmodule CustomTask do
    use Zaik.Agent.TaskRunner

    @impl true
    def run_task(_task, state), do: {:ok, %{custom: true}, state}
  end

  setup do
    original = Application.get_env(:zaik, :task_modules)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:zaik, :task_modules)
        value -> Application.put_env(:zaik, :task_modules, value)
      end
    end)

    Application.delete_env(:zaik, :task_modules)
    :ok
  end

  test "resolves default task modules" do
    assert {:ok, Zaik.Agent.Echo} = Zaik.TaskResolver.resolve(:echo)
    assert {:ok, Zaik.Agent.SystemStatus} = Zaik.TaskResolver.resolve(:system_status)
    assert {:ok, Zaik.Agent.LLM} = Zaik.TaskResolver.resolve(:llm_prompt)
  end

  test "resolves task structs" do
    task = Zaik.Task.new(:echo, %{message: "hello"})

    assert {:ok, Zaik.Agent.Echo} = Zaik.TaskResolver.resolve(task)
  end

  test "configured task modules can add task types" do
    Application.put_env(:zaik, :task_modules, custom: CustomTask)

    assert {:ok, CustomTask} = Zaik.TaskResolver.resolve(:custom)
  end

  test "configured task modules can override defaults" do
    Application.put_env(:zaik, :task_modules, %{echo: CustomTask})

    assert {:ok, CustomTask} = Zaik.TaskResolver.resolve(:echo)
  end

  test "unknown or invalid task types return unknown_task_type" do
    Application.put_env(:zaik, :task_modules, [{"bad", CustomTask}, {:also_bad, "not a module"}])

    assert {:error, :unknown_task_type} = Zaik.TaskResolver.resolve(:missing)
    assert {:error, :unknown_task_type} = Zaik.TaskResolver.resolve("echo")
    assert {:error, :unknown_task_type} = Zaik.TaskResolver.resolve(:bad)
    assert {:error, :unknown_task_type} = Zaik.TaskResolver.resolve(:also_bad)
  end
end

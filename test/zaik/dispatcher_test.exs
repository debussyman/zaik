defmodule Zaik.DispatcherTest do
  use ExUnit.Case, async: false

  describe "public task dispatch" do
    test "submits and awaits an echo task" do
      payload = %{message: "hello"}

      assert {:ok, task_id} = Zaik.submit_task(:echo, payload)
      assert {:ok, ^payload} = Zaik.await_task(task_id, 1_000)
      assert {:ok, %{status: :succeeded, result: ^payload}} = Zaik.get_task(task_id)
    end

    test "marks unknown task types failed" do
      assert {:ok, task_id} = Zaik.submit_task(:unknown_task_type, %{})
      assert {:error, {:task_failed, :unknown_task_type}} = Zaik.await_task(task_id, 1_000)
      assert {:ok, %{status: :failed, error: :unknown_task_type}} = Zaik.get_task(task_id)
    end

    test "session-backed tasks append task and task_result entries" do
      assert {:ok, session} = Zaik.create_session(scope: :dispatcher_test, cwd: "/tmp/dispatcher")
      payload = %{message: "with session"}

      assert {:ok, task_id} = Zaik.submit_task(:echo, payload, session_id: session.id)
      assert {:ok, ^payload} = Zaik.await_task(task_id, 1_000)
      assert {:ok, context} = Zaik.get_session_context(session.id)

      assert Enum.any?(context, &(&1["type"] == "task" and &1["taskId"] == task_id))
      assert Enum.any?(context, &(&1["type"] == "task_result" and &1["taskId"] == task_id))
    end

    test "awaiting a missing task returns not_found" do
      assert {:error, :not_found} = Zaik.await_task("missing-task", 10)
    end
  end
end

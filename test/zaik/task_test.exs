defmodule Zaik.TaskTest do
  use ExUnit.Case, async: true

  describe "new/3" do
    test "creates a queued task with defaults" do
      task = Zaik.Task.new(:echo, %{message: "hello"})

      assert task.id
      assert task.type == :echo
      assert task.payload == %{message: "hello"}
      assert task.priority == 50
      assert task.status == :queued
      assert task.timeout_ms == 60_000
      assert task.max_retries == 0
      assert task.attempts == 0
      assert %DateTime{} = task.submitted_at
    end

    test "accepts session and lifecycle options" do
      task =
        Zaik.Task.new(:llm_prompt, %{prompt: "hello"},
          priority: 90,
          session_id: "session-1",
          parent_entry_id: "entry-1",
          context_entry_id: "entry-2",
          timeout_ms: 5_000,
          max_retries: 2,
          metadata: %{source: :test}
        )

      assert task.priority == 90
      assert task.session_id == "session-1"
      assert task.parent_entry_id == "entry-1"
      assert task.context_entry_id == "entry-2"
      assert task.timeout_ms == 5_000
      assert task.max_retries == 2
      assert task.metadata == %{source: :test}
    end
  end

  describe "status helpers" do
    test "marks running and terminal states" do
      task = Zaik.Task.new(:echo, %{})
      task = Zaik.Task.mark_running(task, self())

      assert task.status == :running
      assert task.agent_pid == self()
      assert %DateTime{} = task.started_at
      refute Zaik.Task.terminal?(task)

      task = Zaik.Task.mark_succeeded(task, %{ok: true})

      assert task.status == :succeeded
      assert task.result == %{ok: true}
      assert %DateTime{} = task.completed_at
      assert Zaik.Task.terminal?(task)
    end

    test "increments attempts" do
      task = Zaik.Task.new(:echo, %{}) |> Zaik.Task.increment_attempts()
      assert task.attempts == 1
    end
  end
end

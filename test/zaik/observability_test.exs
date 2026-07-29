defmodule Zaik.ObservabilityTest do
  use ExUnit.Case, async: false

  test "snapshot exposes core harness state" do
    assert %{
             status: status,
             queue: %{size: queue_size},
             tasks: tasks,
             dispatcher: %{alive?: true},
             agents: %{registered_count: registered_count},
             sessions: %{recent: sessions}
           } = Zaik.snapshot()

    assert status in [:ok, :degraded]
    assert is_integer(queue_size)
    assert is_integer(registered_count)
    assert is_list(sessions)

    for key <- [:queued, :assigned, :running, :succeeded, :failed, :cancelled, :timed_out] do
      assert is_integer(Map.fetch!(tasks, key))
    end
  end

  test "system_status workload updates task summary" do
    before_count = length(Zaik.list_tasks(type: :system_status))

    assert {:ok, task_id} = Zaik.submit_task(:system_status, %{detail: :basic})
    assert {:ok, result} = Zaik.await_task(task_id, 1_000)

    assert is_integer(result.process_count)
    assert is_map(result.memory)
    assert length(Zaik.list_tasks(type: :system_status)) == before_count + 1
  end
end

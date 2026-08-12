defmodule Zaik.TaskQueueTest do
  use ExUnit.Case, async: true

  setup do
    name = unique_name("task_queue")
    start_supervised!({Zaik.TaskQueue, name: name})
    %{queue: name}
  end

  test "dequeues higher priority tasks first", %{queue: queue} do
    low = Zaik.Task.new(:echo, %{}, priority: 10)
    high = Zaik.Task.new(:echo, %{}, priority: 100)
    normal = Zaik.Task.new(:echo, %{}, priority: 50)

    assert :ok = Zaik.TaskQueue.enqueue(queue, low)
    assert :ok = Zaik.TaskQueue.enqueue(queue, high)
    assert :ok = Zaik.TaskQueue.enqueue(queue, normal)

    assert Zaik.TaskQueue.size(queue) == 3
    assert {:ok, task_id} = Zaik.TaskQueue.dequeue(queue)
    assert task_id == high.id
    assert {:ok, task_id} = Zaik.TaskQueue.dequeue(queue)
    assert task_id == normal.id
    assert {:ok, task_id} = Zaik.TaskQueue.dequeue(queue)
    assert task_id == low.id
    assert :empty = Zaik.TaskQueue.dequeue(queue)
  end

  test "preserves FIFO ordering for same priority", %{queue: queue} do
    first = Zaik.Task.new(:echo, %{}, priority: 50)
    second = Zaik.Task.new(:echo, %{}, priority: 50)

    assert :ok = Zaik.TaskQueue.enqueue(queue, first)
    assert :ok = Zaik.TaskQueue.enqueue(queue, second)

    assert {:ok, task_id} = Zaik.TaskQueue.dequeue(queue)
    assert task_id == first.id
    assert {:ok, task_id} = Zaik.TaskQueue.dequeue(queue)
    assert task_id == second.id
  end

  test "removes queued task by ID", %{queue: queue} do
    task = Zaik.Task.new(:echo, %{})

    assert :ok = Zaik.TaskQueue.enqueue(queue, task)
    assert :ok = Zaik.TaskQueue.remove(queue, task.id)
    assert Zaik.TaskQueue.size(queue) == 0
    assert {:error, :not_found} = Zaik.TaskQueue.remove(queue, task.id)
  end

  test "exposes entries and contains checks", %{queue: queue} do
    task = Zaik.Task.new(:echo, %{}, priority: 5)

    refute Zaik.TaskQueue.contains?(queue, task.id)
    assert :ok = Zaik.TaskQueue.enqueue(queue, task)
    assert Zaik.TaskQueue.contains?(queue, task.id)
    assert [%{task_id: task_id, priority: 5}] = Zaik.TaskQueue.entries(queue)
    assert task_id == task.id
  end

  defp unique_name(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end

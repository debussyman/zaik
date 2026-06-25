defmodule Zaik.TaskStoreTest do
  use ExUnit.Case, async: true

  setup do
    name = unique_name("task_store")
    start_supervised!({Zaik.TaskStore, name: name})
    %{store: name}
  end

  test "inserts, fetches, and updates tasks", %{store: store} do
    task = Zaik.Task.new(:echo, %{message: "hello"})

    assert {:ok, ^task} = Zaik.TaskStore.insert(store, task)
    assert {:ok, ^task} = Zaik.TaskStore.get(store, task.id)

    updated = Zaik.Task.mark_failed(task, :boom)
    assert {:ok, ^updated} = Zaik.TaskStore.update(store, updated)
    assert {:ok, %{status: :failed, error: :boom}} = Zaik.TaskStore.get(store, task.id)
  end

  test "returns not found for missing tasks", %{store: store} do
    assert {:error, :not_found} = Zaik.TaskStore.get(store, "missing")
  end

  test "lists tasks by status and type", %{store: store} do
    echo = Zaik.Task.new(:echo, %{})
    llm = Zaik.Task.new(:llm_prompt, %{}) |> Zaik.Task.mark_failed(:bad)

    assert {:ok, _} = Zaik.TaskStore.insert(store, echo)
    assert {:ok, _} = Zaik.TaskStore.insert(store, llm)

    assert [%{id: id}] = Zaik.TaskStore.list(store, status: :failed)
    assert id == llm.id

    assert [%{id: id}] = Zaik.TaskStore.list(store, type: :echo)
    assert id == echo.id
  end

  defp unique_name(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end

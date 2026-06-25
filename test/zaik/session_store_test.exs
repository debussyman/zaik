defmodule Zaik.SessionStoreTest do
  use ExUnit.Case, async: true

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "zaik-session-test-#{System.unique_integer([:positive])}")

    name = unique_name("session_store")
    start_supervised!({Zaik.SessionStore, name: name, base_dir: base_dir})

    on_exit(fn -> File.rm_rf(base_dir) end)

    %{store: name, base_dir: base_dir}
  end

  test "creates a JSONL session file with header", %{store: store} do
    assert {:ok, session} = Zaik.SessionStore.create(store, scope: :project, cwd: "/tmp/example")
    assert File.exists?(session.path)

    [header_line] = File.read!(session.path) |> String.split("\n", trim: true)
    assert {:ok, header} = Jason.decode(header_line)
    assert header["type"] == "session"
    assert header["version"] == 1
    assert header["id"] == session.id
    assert header["scope"] == "project"
    assert header["cwd"] == "/tmp/example"
  end

  test "appends entries and returns active branch", %{store: store} do
    assert {:ok, session} = Zaik.SessionStore.create(store, scope: :chat, cwd: "/tmp/example")

    assert {:ok, first_id} =
             Zaik.SessionStore.append(store, session.id, %{
               type: "message",
               role: "user",
               content: "hello"
             })

    assert {:ok, second_id} =
             Zaik.SessionStore.append(store, session.id, %{
               type: "task",
               taskId: "task-1",
               taskType: "echo"
             })

    assert {:ok, branch} = Zaik.SessionStore.get_branch(store, session.id)
    assert Enum.map(branch, & &1["id"]) == [first_id, second_id]
    assert [first, second] = branch
    assert first["parentId"] == nil
    assert second["parentId"] == first_id
  end

  test "can branch to an earlier entry", %{store: store} do
    assert {:ok, session} = Zaik.SessionStore.create(store, [])

    assert {:ok, first_id} =
             Zaik.SessionStore.append(store, session.id, %{type: "message", content: "one"})

    assert {:ok, _second_id} =
             Zaik.SessionStore.append(store, session.id, %{type: "message", content: "two"})

    assert {:ok, _session} = Zaik.SessionStore.branch(store, session.id, first_id)
    assert {:ok, branch} = Zaik.SessionStore.get_branch(store, session.id)

    assert Enum.map(branch, & &1["content"]) == ["one"]
  end

  test "reopens session from disk", %{store: store, base_dir: base_dir} do
    assert {:ok, session} = Zaik.SessionStore.create(store, [])

    assert {:ok, entry_id} =
             Zaik.SessionStore.append(store, session.id, %{type: "message", content: "persisted"})

    new_store = unique_name("session_store_reopen")

    start_supervised!(%{
      id: new_store,
      start: {Zaik.SessionStore, :start_link, [[name: new_store, base_dir: base_dir]]}
    })

    assert {:ok, reopened} = Zaik.SessionStore.open(new_store, session.path)
    assert reopened.id == session.id
    assert reopened.current_leaf_id == entry_id

    assert {:ok, [%{"content" => "persisted"}]} =
             Zaik.SessionStore.get_branch(new_store, reopened.id)
  end

  defp unique_name(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end

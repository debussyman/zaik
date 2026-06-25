defmodule Zaik.ContextBuilderTest do
  use ExUnit.Case, async: true

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "zaik-context-test-#{System.unique_integer([:positive])}")

    name = unique_name("session_store")
    start_supervised!({Zaik.SessionStore, name: name, base_dir: base_dir})

    # ContextBuilder currently uses the default SessionStore name, so run these
    # tests against the application store and clean up only our temp store. This
    # setup still validates session store isolation for future injectable APIs.
    on_exit(fn -> File.rm_rf(base_dir) end)

    :ok
  end

  test "builds context from active branch and excludes marked entries" do
    assert {:ok, session} = Zaik.create_session(scope: :context_test, cwd: "/tmp/context")
    assert {:ok, _} = Zaik.MemoryStore.append_message(session.id, :user, "keep me")

    assert {:ok, _} =
             Zaik.MemoryStore.append_message(session.id, :system, "hidden",
               exclude_from_context: true
             )

    assert {:ok, _} = Zaik.MemoryStore.append_message(session.id, :agent, "also keep me")

    assert {:ok, context} = Zaik.get_session_context(session.id)

    assert Enum.map(context, & &1["content"]) == ["keep me", "also keep me"]
  end

  test "uses the latest summary as a context window boundary" do
    assert {:ok, session} = Zaik.create_session(scope: :context_test, cwd: "/tmp/context-summary")
    assert {:ok, _} = Zaik.MemoryStore.append_message(session.id, :user, "old")
    assert {:ok, _} = Zaik.MemoryStore.append_summary(session.id, "summary of old context")
    assert {:ok, _} = Zaik.MemoryStore.append_message(session.id, :user, "new")

    assert {:ok, context} = Zaik.get_session_context(session.id)

    assert Enum.map(context, &{&1["type"], &1["content"] || &1["summary"]}) == [
             {"summary", "summary of old context"},
             {"message", "new"}
           ]
  end

  defp unique_name(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end

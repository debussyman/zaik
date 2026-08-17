defmodule Zaik.Analytics.SQLToolTest do
  use ExUnit.Case, async: false

  test "validates read-only queries against allowed ops views" do
    assert {:ok, _} = Zaik.Analytics.SQLTool.validate("SELECT id FROM zaik_tasks LIMIT 5", :ops)

    assert {:ok, _} =
             Zaik.Analytics.SQLTool.validate(
               "WITH recent AS (SELECT id FROM zaik_tasks) SELECT id FROM recent",
               :ops
             )

    assert {:error, :only_select_queries_allowed} =
             Zaik.Analytics.SQLTool.validate("DELETE FROM zaik_tasks", :ops)

    assert {:error, :multiple_statements_not_allowed} =
             Zaik.Analytics.SQLTool.validate(
               "SELECT * FROM zaik_tasks; DROP TABLE ops_tasks",
               :ops
             )

    assert {:error, :disallowed_sql_keyword} =
             Zaik.Analytics.SQLTool.validate(
               "SELECT * FROM zaik_tasks PRAGMA table_info(zaik_tasks)",
               :ops
             )

    assert {:error, {:disallowed_relation, ["ops_tasks"]}} =
             Zaik.Analytics.SQLTool.validate("SELECT id FROM ops_tasks", :ops)
  end

  test "validates read-only queries against allowed home views" do
    assert {:ok, _} =
             Zaik.Analytics.SQLTool.validate(
               "SELECT temperature_f FROM home_readings LIMIT 10",
               :home
             )

    assert {:error, {:disallowed_relation, ["readings"]}} =
             Zaik.Analytics.SQLTool.validate("SELECT temperature_c FROM readings", :home)
  end

  test "runs safe ops queries with row maps" do
    task_id = "sql-tool-#{System.unique_integer([:positive])}"
    task = Zaik.Task.new(:echo, %{message: "hello"}, id: task_id)

    assert :ok = Zaik.TelemetryStore.record_task(task, :test)

    assert {:ok, %{columns: ["id", "type"], rows: [%{"id" => ^task_id, "type" => "echo"}]}} =
             Zaik.Analytics.SQLTool.run(
               "SELECT id, type FROM zaik_tasks WHERE id = '#{task_id}'",
               db: :ops,
               limit: 5
             )
  end
end

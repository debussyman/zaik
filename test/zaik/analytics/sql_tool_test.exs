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

  test "infers the database from an allowed view when the model omits or mislabels it" do
    assert Zaik.Analytics.SQLTool.database_for("SELECT * FROM home_readings", :ops) == :home
    assert Zaik.Analytics.SQLTool.database_for("SELECT * FROM zaik_tasks", :home) == :ops
    assert Zaik.Analytics.SQLTool.database_for("SELECT 1", :home) == :home

    assert Zaik.Analytics.SQLTool.run("SELECT 1", db: :unknown) ==
             {:error, {:unsupported_database, :unknown}}
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

  test "rejects common hallucinated home columns" do
    assert {:error, {:unknown_home_column, "room_name"}} =
             Zaik.Analytics.SQLTool.validate(
               "SELECT temperature_f FROM home_readings WHERE lower(room_name) LIKE '%lily%' LIMIT 1",
               :home
             )

    assert {:error, {:unknown_home_column, "friendly_name"}} =
             Zaik.Analytics.SQLTool.validate(
               "SELECT temperature_f FROM home_readings WHERE lower(friendly_name) LIKE '%lily%' LIMIT 1",
               :home
             )

    assert {:error, {:unknown_home_column, "device"}} =
             Zaik.Analytics.SQLTool.validate(
               "SELECT temperature_f FROM home_readings WHERE lower(device) LIKE '%lily%' LIMIT 1",
               :home
             )

    assert {:error, {:unknown_home_column, "created_at"}} =
             Zaik.Analytics.SQLTool.validate(
               "SELECT created_at, temperature_f FROM home_readings WHERE lower(room) LIKE '%lily%' LIMIT 10",
               :home
             )

    assert {:ok, _} =
             Zaik.Analytics.SQLTool.validate(
               "SELECT temperature_f FROM home_readings WHERE area_id = 'lily_bedroom' LIMIT 10",
               :home
             )

    assert {:error, {:unknown_home_column, "entity_name"}} =
             Zaik.Analytics.SQLTool.validate(
               "SELECT temperature_f FROM home_readings WHERE entity_name = 'lily_bedroom' LIMIT 10",
               :home
             )
  end

  test "requires non-null filter for latest temperature lookups" do
    assert {:error, {:missing_non_null_filter, "temperature_f"}} =
             Zaik.Analytics.SQLTool.validate(
               "SELECT recorded_at, temperature_f FROM home_readings WHERE lower(device_name) LIKE '%lily%' ORDER BY recorded_at DESC LIMIT 1",
               :home
             )

    assert {:error, {:mis_scoped_non_null_filter, "temperature_f"}} =
             Zaik.Analytics.SQLTool.validate(
               "SELECT recorded_at, temperature_f FROM home_readings WHERE lower(device_name) LIKE '%lily%' OR lower(room) LIKE '%lily%' AND temperature_f IS NOT NULL ORDER BY recorded_at DESC LIMIT 1",
               :home
             )

    assert {:error, {:mis_scoped_non_null_filter, "temperature_f"}} =
             Zaik.Analytics.SQLTool.validate(
               "SELECT recorded_at, temperature_f FROM home_readings WHERE lower(device_name) LIKE '%lily%' OR lower(room) LIKE '%lily%' AND temperature_f IS NOT NULL AND recorded_at >= datetime('now', '-3 hours') ORDER BY recorded_at ASC",
               :home
             )

    assert {:ok, _} =
             Zaik.Analytics.SQLTool.validate(
               "SELECT recorded_at, temperature_f FROM home_readings WHERE (lower(device_name) LIKE '%lily%' OR lower(room) LIKE '%lily%') AND temperature_f IS NOT NULL ORDER BY recorded_at DESC LIMIT 1",
               :home
             )
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

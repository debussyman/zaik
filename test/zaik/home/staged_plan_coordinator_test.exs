defmodule Zaik.Home.StagedPlanCoordinatorTest do
  use ExUnit.Case, async: true

  test "production and incomplete bindings are rejected before supervision or execution" do
    assert {:error, :staged_plan_execution_not_enabled} =
             Zaik.Home.StagedPlanCoordinator.run("plan", %{})

    assert {:error, :staged_plan_execution_not_enabled} =
             Zaik.Home.StagedPlanCoordinator.run("plan", %{
               mirror_scenario_id: "forged",
               executor_opts: [modules: [Zaik.Home.Executors.Cover]]
             })
  end

  test "the automatic scheduler also refuses production-shaped contexts" do
    Process.flag(:trap_exit, true)

    assert {:error, :staged_plan_scheduler_not_enabled} =
             Zaik.Home.StagedPlanScheduler.start_link(
               context: %{
                 mirror_scenario_id: "forged",
                 executor_opts: [modules: [Zaik.Home.Executors.Cover]]
               }
             )
  end
end

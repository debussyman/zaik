defmodule Zaik.TelemetryWriteMonitorTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, monitor} = start_supervised({Zaik.TelemetryWriteMonitor, name: nil, max_events: 3})
    %{monitor: monitor}
  end

  test "exposes required write failures until the category writes successfully", %{
    monitor: monitor
  } do
    assert {:error, "disk_full"} =
             Zaik.TelemetryWriteMonitor.report(
               :agent_chat_trace,
               {:error, :disk_full},
               %{trace_id: "trace-1"},
               monitor
             )

    assert %{
             status: :degraded,
             failure_count: 1,
             unresolved: [
               %{
                 category: :agent_chat_trace,
                 status: :failed,
                 failures: 1,
                 last_failure: "disk_full"
               }
             ]
           } = Zaik.TelemetryWriteMonitor.status(monitor)

    assert :ok =
             Zaik.TelemetryWriteMonitor.report(
               :agent_chat_trace,
               :ok,
               %{trace_id: "trace-2"},
               monitor
             )

    assert %{status: :ok, unresolved: [], failure_count: 1, recent: recent} =
             Zaik.TelemetryWriteMonitor.status(monitor)

    assert length(recent) == 2
  end

  test "bounds the in-memory diagnostic window", %{monitor: monitor} do
    for index <- 1..5 do
      Zaik.TelemetryWriteMonitor.report(
        :autonomy_decision,
        {:error, {:write_failed, index}},
        %{decision_id: "decision-#{index}"},
        monitor
      )
    end

    assert %{failure_count: 5, recent: recent} = Zaik.TelemetryWriteMonitor.status(monitor)
    assert length(recent) == 3
  end
end

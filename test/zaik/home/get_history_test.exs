defmodule Zaik.Home.GetHistoryTest do
  use ExUnit.Case, async: true

  test "translates a relative window using the injected clock" do
    {:ok, history} =
      start_supervised({Zaik.Home.HistoryStore, name: nil, db_path: ":memory:"})

    {:ok, clock} =
      start_supervised(
        {Zaik.Home.Mirror.Clock, name: nil, now: ~U[2026-08-14 12:00:00Z]},
        id: :history_clock
      )

    :ok =
      Zaik.Home.HistoryStore.record_device(
        history,
        "Nursery sensor",
        %{"humidity" => 45},
        %{"ieee_address" => "sensor-1", "area_id" => "nursery"},
        observed_at: ~U[2026-08-14 10:00:00Z]
      )

    :ok =
      Zaik.Home.HistoryStore.record_device(
        history,
        "Nursery sensor",
        %{"humidity" => 50},
        %{"ieee_address" => "sensor-1", "area_id" => "nursery"},
        observed_at: ~U[2026-08-14 11:45:00Z]
      )

    assert {:ok, [reading]} =
             Zaik.Home.Tools.GetHistory.run(
               %{
                 "query" => "nursery",
                 "capability" => "humidity",
                 "since_minutes" => 30
               },
               %{
                 history_store: history,
                 clock: {Zaik.Home.Mirror.Clock, clock}
               }
             )

    assert reading.value == 50.0
    assert reading.observed_at == "2026-08-14T11:45:00Z"
  end
end

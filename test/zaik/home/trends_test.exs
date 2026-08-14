defmodule Zaik.Home.TrendsTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, history} = start_supervised({Zaik.Home.HistoryStore, name: nil, db_path: ":memory:"})
    %{history: history}
  end

  test "detects cooling over the requested window", %{history: history} do
    Zaik.Home.HistoryStore.record_device(
      history,
      "Lily's room multi-sensor",
      %{"temperature" => 27.0},
      %{},
      observed_at: ~U[2026-08-14 11:00:00Z]
    )

    Zaik.Home.HistoryStore.record_device(
      history,
      "Lily's room multi-sensor",
      %{"temperature" => 26.0},
      %{},
      observed_at: ~U[2026-08-14 12:00:00Z]
    )

    assert {:ok, trend} =
             Zaik.Home.Trends.analyze("lily",
               history_store: history,
               now: ~U[2026-08-14 12:00:00Z],
               window_seconds: 3600
             )

    assert trend.temperature.trend == :falling
    assert Float.round(trend.temperature.current, 1) == 78.8
    assert Float.round(trend.temperature.delta, 1) == -1.8
  end

  test "requires at least two readings", %{history: history} do
    Zaik.Home.HistoryStore.record_device(history, "Lily", %{"temperature" => 27.0}, %{},
      observed_at: ~U[2026-08-14 12:00:00Z]
    )

    assert {:error, :insufficient_data} =
             Zaik.Home.Trends.analyze("lily",
               history_store: history,
               now: ~U[2026-08-14 12:00:00Z],
               window_seconds: 3600
             )
  end
end

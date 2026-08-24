defmodule Zaik.Alerts.EngineTest do
  use ExUnit.Case, async: false

  defmodule FakeNotifier do
    def send_message(chat_id, text) do
      send(Process.whereis(:zaik_alert_test), {:alert_notification, chat_id, text})
      {:ok, %{chat_id: chat_id, text: text}}
    end
  end

  setup do
    Process.register(self(), :zaik_alert_test)

    on_exit(fn ->
      if Process.whereis(:zaik_alert_test), do: Process.unregister(:zaik_alert_test)
    end)

    :ok
  end

  test "triggers presence alerts and suppresses notifications during cooldown" do
    suffix = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "zaik-alert-engine-#{suffix}.json")
    store = Module.concat(__MODULE__, "Store#{suffix}")
    engine = Module.concat(__MODULE__, "Engine#{suffix}")

    start_supervised!(
      {Zaik.Alerts.RuleStore, name: store, path: path, default_cooldown_seconds: 900}
    )

    start_supervised!(
      {Zaik.Alerts.Engine, name: engine, rule_store: store, notifier: FakeNotifier}
    )

    now = ~U[2026-08-24 12:00:00Z]

    assert {:ok, rule} =
             Zaik.Alerts.RuleStore.create(
               %{
                 type: :presence_detected,
                 scope: :home,
                 starts_at: DateTime.add(now, -60, :second),
                 ends_at: DateTime.add(now, 3600, :second),
                 notify_channel: :telegram,
                 notify_chat_id: "chat-1",
                 cooldown_seconds: 900
               },
               store
             )

    payload = %{"presence" => true, "temperature" => 27.0, "linkquality" => 80}
    metadata = %{"topic" => "zigbee2mqtt/Main bedroom multi-sensor"}

    assert %{triggered: 1, suppressed: 0, errors: 0} =
             Zaik.Alerts.Engine.evaluate_device_update(
               engine,
               "Main bedroom multi-sensor",
               payload,
               metadata,
               now: now
             )

    assert_receive {:alert_notification, "chat-1", text}
    assert text =~ "Presence detected at Main bedroom multi-sensor."
    assert text =~ "Temperature: 80.6°F"
    assert text =~ "Linkquality: 80"
    assert text =~ rule["id"]

    assert %{triggered: 0, suppressed: 1, errors: 0} =
             Zaik.Alerts.Engine.evaluate_device_update(
               engine,
               "Main bedroom multi-sensor",
               payload,
               metadata,
               now: DateTime.add(now, 60, :second)
             )

    refute_receive {:alert_notification, _, _}, 50

    assert %{triggered: 1, suppressed: 0, errors: 0} =
             Zaik.Alerts.Engine.evaluate_device_update(
               engine,
               "Main bedroom multi-sensor",
               payload,
               metadata,
               now: DateTime.add(now, 901, :second)
             )

    assert_receive {:alert_notification, "chat-1", _text}
  end

  test "ignores updates without presence" do
    suffix = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "zaik-alert-engine-ignore-#{suffix}.json")
    store = Module.concat(__MODULE__, "IgnoreStore#{suffix}")
    engine = Module.concat(__MODULE__, "IgnoreEngine#{suffix}")

    start_supervised!({Zaik.Alerts.RuleStore, name: store, path: path})

    start_supervised!(
      {Zaik.Alerts.Engine, name: engine, rule_store: store, notifier: FakeNotifier}
    )

    assert %{triggered: 0, suppressed: 0, errors: 0} =
             Zaik.Alerts.Engine.evaluate_device_update(
               engine,
               "Sensor",
               %{"presence" => false},
               %{}
             )
  end
end

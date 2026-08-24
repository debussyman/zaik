defmodule Zaik.Alerts.RuleStoreTest do
  use ExUnit.Case, async: true

  test "creates, lists, persists, triggers, and cancels alert rules" do
    path =
      Path.join(
        System.tmp_dir!(),
        "zaik-alert-rule-store-#{System.unique_integer([:positive])}.json"
      )

    name = Module.concat(__MODULE__, "Store#{System.unique_integer([:positive])}")

    start_supervised!(
      {Zaik.Alerts.RuleStore, name: name, path: path, default_cooldown_seconds: 60}
    )

    ends_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    assert {:ok, rule} =
             Zaik.Alerts.RuleStore.create(
               %{
                 type: :presence_detected,
                 scope: :home,
                 ends_at: ends_at,
                 notify_channel: :telegram,
                 notify_chat_id: "chat-1"
               },
               name
             )

    assert rule["id"] =~ "alert_"
    assert rule["status"] == "active"
    assert rule["cooldown_seconds"] == 60
    assert [^rule] = Zaik.Alerts.RuleStore.list(:active, name)

    assert {:ok, triggered} =
             Zaik.Alerts.RuleStore.record_trigger(rule["id"], DateTime.utc_now(), name)

    assert triggered["trigger_count"] == 1
    assert triggered["last_triggered_at"]

    assert {:ok, cancelled} = Zaik.Alerts.RuleStore.cancel(rule["id"], name)
    assert cancelled["status"] == "cancelled"
    assert [] = Zaik.Alerts.RuleStore.list(:active, name)
    assert [persisted] = Jason.decode!(File.read!(path))
    assert persisted["id"] == rule["id"]
  end
end

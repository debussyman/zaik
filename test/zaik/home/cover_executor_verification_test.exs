defmodule Zaik.Home.CoverExecutorVerificationPublisher do
  def publish(_topic, payload, _opts) do
    report =
      case payload do
        %{"state" => "CLOSE"} -> %{"state" => "CLOSE", "position" => 0}
        %{"state" => "OPEN"} -> %{"state" => "OPEN", "position" => 100}
        other -> other
      end

    Zaik.Home.ActionVerifier.observe(
      "Office blind",
      report,
      DateTime.utc_now(),
      server: Zaik.Home.CoverExecutorVerificationVerifier
    )

    :ok
  end
end

defmodule Zaik.Home.CoverExecutorVerificationTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, verifier} =
      start_supervised(
        {Zaik.Home.ActionVerifier,
         name: Zaik.Home.CoverExecutorVerificationVerifier, timeout_ms: 500, wait_ms: 100}
      )

    {:ok, store} = start_supervised({Zaik.Home.DeviceStore, name: nil})

    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Office blind",
      %{"position" => 50, "state" => "STOP"},
      %{"ieee_address" => "office", "manufacturer" => "Smartwings"}
    )

    {:ok, entity} = Zaik.Home.World.get("Office blind", device_store: store, capability: "cover")

    %{verifier: verifier, store: store, entity: entity}
  end

  test "returns verified only after the reported cover state converges", %{
    verifier: verifier,
    store: store,
    entity: entity
  } do
    assert {:ok, result} =
             Zaik.Home.Executors.Cover.execute(
               entity,
               %{"position" => 37},
               %{
                 action_id: "office-position",
                 action_verifier: verifier,
                 verification_wait_ms: 100,
                 device_store: store,
                 mqtt_client: Zaik.Home.CoverExecutorVerificationPublisher
               }
             )

    assert result.action_id == "office-position"
    assert result.status == "verified"
    assert result.verified == true
    assert result.verification_status == "verified"
    assert result.observed == %{"position" => 37}
  end
end

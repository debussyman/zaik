defmodule Zaik.Home.ActionRetryPolicyTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, store} = start_supervised({Zaik.Home.DeviceStore, name: nil})

    %{store: store, requested_at: DateTime.add(DateTime.utc_now(), -10, :second)}
  end

  test "allows an expired idempotent target only after fresh state proves non-convergence", %{
    store: store,
    requested_at: requested_at
  } do
    put_blind(store, 50)
    entry = entry(requested_at, "expired")

    assert {:ok, decision} =
             Zaik.Home.ActionRetryPolicy.evaluate(
               entry,
               %{device_store: store, action_ledger: nil},
               settle_ms: 0,
               cooldown_ms: 0
             )

    assert decision.eligible == true
    assert decision.reason == "fresh_state_not_converged"

    assert decision.retry_args == %{
             "device" => "Office blind",
             "capability" => "cover",
             "target" => %{"position" => 37}
           }
  end

  test "does not retry while verification is still pending", %{
    store: store,
    requested_at: requested_at
  } do
    put_blind(store, 50)

    entry =
      entry(requested_at, "pending")
      |> put_in(
        [:result, :verification_expires_at],
        DateTime.add(DateTime.utc_now(), 30, :second) |> DateTime.to_iso8601()
      )

    assert {:ok, decision} =
             Zaik.Home.ActionRetryPolicy.evaluate(
               entry,
               %{device_store: store, action_ledger: nil},
               settle_ms: 0
             )

    assert decision.eligible == false
    assert decision.reason == "verification_still_pending"
  end

  test "reconciles an already-converged target instead of retrying", %{
    store: store,
    requested_at: requested_at
  } do
    put_blind(store, 37)
    entry = entry(requested_at, "expired")

    assert {:ok, decision} =
             Zaik.Home.ActionRetryPolicy.evaluate(
               entry,
               %{device_store: store, action_ledger: nil},
               settle_ms: 0
             )

    assert decision.eligible == false
    assert decision.reason == "already_converged"
    assert decision.reconciled_action_ids == ["original-action"]
  end

  test "retries only unresolved actions from a coordinated plan", %{
    store: store,
    requested_at: requested_at
  } do
    put_blind(store, 37)

    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Hall blind",
      %{"position" => 50, "state" => "STOP"},
      %{"ieee_address" => "hall", "manufacturer" => "Smartwings"}
    )

    entry = %{
      idempotency_key: "plan-action",
      tool: "execute_home_plan",
      status: "succeeded",
      result: %{
        plan_id: "bedtime",
        actions: [
          %{
            action: %{device: "Office blind", capability: "cover", target: %{"position" => 37}},
            result: %{
              action_id: "child-verified",
              device: "Office blind",
              capability: "cover",
              target: %{"position" => 37},
              verified: true,
              verification_status: "verified",
              requested_at: DateTime.to_iso8601(requested_at)
            }
          },
          %{
            action: %{device: "Hall blind", capability: "cover", target: %{"position" => 20}},
            result: %{
              action_id: "child-expired",
              device: "Hall blind",
              capability: "cover",
              target: %{"position" => 20},
              verified: false,
              verification_status: "expired",
              verification_expires_at:
                DateTime.add(requested_at, 5, :second) |> DateTime.to_iso8601(),
              requested_at: DateTime.to_iso8601(requested_at)
            }
          }
        ]
      }
    }

    assert {:ok, decision} =
             Zaik.Home.ActionRetryPolicy.evaluate(
               entry,
               %{device_store: store, action_ledger: nil},
               settle_ms: 0,
               cooldown_ms: 0
             )

    assert decision.eligible == true

    assert decision.retry_args["actions"] == [
             %{
               "device" => "Hall blind",
               "capability" => "cover",
               "target" => %{"position" => 20}
             }
           ]
  end

  test "blocks retry without a fresh post-action state report", %{
    store: store,
    requested_at: requested_at
  } do
    put_blind(store, 50)

    :sys.replace_state(store, fn state ->
      devices =
        Map.new(state.devices, fn {key, device} ->
          {key, %{device | received_at: DateTime.add(requested_at, -1, :second)}}
        end)

      %{state | devices: devices}
    end)

    assert {:ok, decision} =
             Zaik.Home.ActionRetryPolicy.evaluate(
               entry(requested_at, "expired"),
               %{device_store: store, action_ledger: nil},
               settle_ms: 0
             )

    assert decision.eligible == false
    assert decision.reason == "fresh_post_action_state_required"
  end

  defp put_blind(store, position) do
    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Office blind",
      %{"position" => position, "state" => "STOP"},
      %{"ieee_address" => "office", "manufacturer" => "Smartwings"}
    )
  end

  defp entry(requested_at, verification_status) do
    %{
      idempotency_key: "original-action",
      tool: "control_device",
      status: "succeeded",
      result: %{
        action_id: "original-action",
        device: "Office blind",
        capability: "cover",
        target: %{"position" => 37},
        status: "accepted",
        verified: false,
        verification_status: verification_status,
        verification_expires_at: DateTime.add(requested_at, 5, :second) |> DateTime.to_iso8601(),
        requested_at: DateTime.to_iso8601(requested_at)
      }
    }
  end
end

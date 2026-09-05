defmodule Zaik.Home.RetryActionTest do
  use ExUnit.Case, async: true

  defmodule FakeCoverExecutor do
    @behaviour Zaik.Home.Executor

    def capability, do: "cover"

    def execute(entity, target, context) do
      send(context.test_pid, {:retried, entity.id, target})

      {:ok,
       %{
         action_id: context.action_id,
         entity_id: entity.id,
         device: entity.name,
         capability: "cover",
         target: target,
         status: "accepted",
         verified: false
       }}
    end
  end

  setup do
    {:ok, ledger} = start_supervised({Zaik.Home.ActionLedger, name: nil, db_path: ":memory:"})
    {:ok, supervisor} = start_supervised({Task.Supervisor, name: nil})
    {:ok, store} = start_supervised({Zaik.Home.DeviceStore, name: nil})

    Zaik.Home.DeviceStore.upsert_device(
      store,
      "Office blind",
      %{"position" => 50, "state" => "STOP"},
      %{"ieee_address" => "office", "manufacturer" => "Smartwings"}
    )

    original_context = %{channel: :telegram, chat_id: "-100", message_id: 100}

    original_args = %{
      "device" => "Office blind",
      "capability" => "cover",
      "target" => %{"position" => 37}
    }

    {:ok, original_id} =
      Zaik.Home.ActionLedger.claim("control_device", original_args, original_context, ledger)

    requested_at = DateTime.add(DateTime.utc_now(), -10, :second)

    :ok =
      Zaik.Home.ActionLedger.complete(
        original_id,
        {:ok,
         %{
           action_id: original_id,
           device: "Office blind",
           capability: "cover",
           target: %{"position" => 37},
           status: "accepted",
           verified: false,
           verification_status: "expired",
           verification_expires_at:
             DateTime.add(requested_at, 5, :second) |> DateTime.to_iso8601(),
           requested_at: DateTime.to_iso8601(requested_at)
         }},
        ledger
      )

    registry_opts = [modules: [Zaik.Home.Tools.RetryAction, Zaik.Home.Tools.ControlDevice]]

    context = %{
      channel: :telegram,
      chat_id: "-100",
      message_id: 101,
      action_ledger: ledger,
      device_store: store,
      executor_opts: [modules: [FakeCoverExecutor]],
      registry_opts: registry_opts,
      retry_policy_opts: [settle_ms: 0, cooldown_ms: 0, max_attempts: 1],
      test_pid: self()
    }

    %{
      ledger: ledger,
      supervisor: supervisor,
      original_id: original_id,
      registry_opts: registry_opts,
      context: context
    }
  end

  test "returns verified without replay when current state already converged", state do
    Zaik.Home.DeviceStore.upsert_device(
      state.context.device_store,
      "Office blind",
      %{"position" => 37},
      %{}
    )

    assert {:ok, result} =
             Zaik.Tools.Executor.run(
               "retry_home_action",
               %{"action_id" => state.original_id},
               state.context,
               ledger: state.ledger,
               task_supervisor: state.supervisor,
               registry_opts: state.registry_opts
             )

    assert result.status == "verified"
    assert result.retried == false
    refute_received {:retried, _entity, _target}
    assert Zaik.Home.ActionLedger.retries_for(state.original_id, state.ledger) == []
  end

  test "retries an eligible target once through the original typed tool", state do
    assert {:ok, retry_result} =
             Zaik.Tools.Executor.run(
               "retry_home_action",
               %{"action_id" => state.original_id},
               state.context,
               ledger: state.ledger,
               task_supervisor: state.supervisor,
               registry_opts: state.registry_opts
             )

    assert retry_result.retry_of == state.original_id
    assert retry_result.retry_attempt == 1
    assert_received {:retried, "office", %{"position" => 37}}
    assert length(Zaik.Home.ActionLedger.retries_for(state.original_id, state.ledger)) == 1

    second_context = %{state.context | message_id: 102}

    assert {:error, {:retry_not_eligible, decision}} =
             Zaik.Tools.Executor.run(
               "retry_home_action",
               %{"action_id" => state.original_id},
               second_context,
               ledger: state.ledger,
               task_supervisor: state.supervisor,
               registry_opts: state.registry_opts
             )

    assert decision.reason == "retry_budget_exhausted"
    refute_received {:retried, "office", %{"position" => 37}}
    assert length(Zaik.Home.ActionLedger.retries_for(state.original_id, state.ledger)) == 1
  end
end

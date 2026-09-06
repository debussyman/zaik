defmodule Zaik.Home.Mirror.Scenarios do
  @moduledoc """
  Reusable deterministic mirror scenarios for regression and live-model evals.
  """

  alias Zaik.Home.Mirror.Scenario

  def lily_bedtime_with_ac(opts \\ []) do
    Scenario.new!(%{
      id: Keyword.get(opts, :id, "lily_bedtime_with_ac"),
      description: "Close Lily's left blind and leave the right blind above the AC.",
      areas: [%{id: "lily_bedroom", name: "Lily's room"}],
      entities: [
        %{
          id: "eval-sensor",
          name: "Lily's room multi-sensor",
          area_id: "lily_bedroom",
          capabilities: ["temperature", "humidity", "illuminance", "presence"],
          payload: %{
            "temperature" => 25.7777778,
            "humidity" => 56,
            "illuminance" => 220,
            "presence" => true
          }
        },
        %{
          id: "eval-left",
          name: "Lily's bedroom left blind",
          area_id: "lily_bedroom",
          capabilities: ["cover"],
          payload: %{"position" => 100, "state" => "OPEN"},
          metadata: %{"manufacturer" => "Smartwings"}
        },
        %{
          id: "eval-right",
          name: "Lily's bedroom right blind",
          area_id: "lily_bedroom",
          capabilities: ["cover"],
          payload: %{"position" => 100, "state" => "OPEN"},
          metadata: %{"manufacturer" => "Smartwings"}
        }
      ],
      presets: [
        %{
          device: "Lily's bedroom right blind",
          name: "above AC",
          capability: "cover",
          target: %{"position" => 71}
        }
      ],
      desired_state: [
        %{
          device: "Lily's bedroom left blind",
          capability: "cover",
          target: %{"state" => "CLOSE"}
        },
        %{
          device: "Lily's bedroom right blind",
          capability: "cover",
          target: %{"position" => 71}
        }
      ],
      faults: Keyword.get(opts, :faults, %{}),
      metadata:
        Map.merge(
          %{max_side_effects: 2, verification_wait_ms: 0},
          Map.new(Keyword.get(opts, :metadata, %{}))
        )
    })
  end
end

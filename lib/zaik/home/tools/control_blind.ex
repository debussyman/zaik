defmodule Zaik.Home.Tools.ControlBlind do
  @moduledoc false
  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "control_blind",
      aliases: ["set_blind", "blind_control"],
      description: "Request a validated low-risk target for a known window covering.",
      kind: :action,
      risk: :low,
      input_schema: %{
        "type" => "object",
        "required" => ["device", "target"],
        "properties" => %{
          "device" => %{"type" => "string"},
          "target" => %{
            "type" => "object",
            "properties" => %{
              "state" => %{"type" => "string", "enum" => ["OPEN", "CLOSE", "STOP"]},
              "position" => %{"type" => "integer", "minimum" => 0, "maximum" => 100},
              "preset" => %{"type" => "string"}
            }
          }
        }
      }
    }
  end

  @impl true
  def run(args, context) do
    implementation =
      Map.get(context, :control_tool) || Map.get(context, "control_tool") ||
        Zaik.Home.ControlTool

    implementation.run("control_blind", args, context)
  end
end

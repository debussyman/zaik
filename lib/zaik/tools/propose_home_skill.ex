defmodule Zaik.Tools.ProposeHomeSkill do
  @moduledoc false
  @behaviour Zaik.Tool

  @impl true
  def descriptor do
    %{
      name: "propose_home_skill",
      aliases: ["draft_home_skill"],
      description:
        "Create a validated operator-confirmation proposal for a home goal skill. This never writes or activates the skill.",
      kind: :action,
      risk: :low,
      input_schema: %{
        "type" => "object",
        "required" => ["name", "triggers", "body", "contract"],
        "properties" => %{
          "name" => %{"type" => "string"},
          "domain" => %{"type" => "string", "enum" => ["home"]},
          "risk" => %{"type" => "string", "enum" => ["none", "low", "medium", "high"]},
          "triggers" => %{"type" => "array", "items" => %{"type" => "string"}},
          "body" => %{"type" => "string"},
          "contract" => %{
            "type" => "object",
            "required" => [
              "schema_version",
              "goal_id",
              "scope",
              "required_observations",
              "allowed_tools",
              "risk_ceiling",
              "missing_data_policy"
            ]
          }
        }
      }
    }
  end

  @impl true
  def run(args, context) when is_map(args) do
    skill =
      args
      |> Map.put_new("domain", "home")
      |> Map.put_new("risk", "low")

    created_by =
      value(context, :sender_id) || value(context, :sender_name) || value(context, :created_by) ||
        "operator"

    case Zaik.SkillAuthoring.propose(skill, to_string(created_by),
           tool_registry_opts: value(context, :registry_opts) || []
         ) do
      {:ok, proposal} ->
        {:ok,
         %{
           proposal_id: proposal.id,
           status: proposal.status,
           goal_id: value(proposal.metadata, :goal_id),
           scope: value(proposal.metadata, :scope),
           confirmation_required: true,
           skill_written: false
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
end

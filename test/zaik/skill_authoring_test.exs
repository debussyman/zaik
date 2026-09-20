defmodule Zaik.SkillAuthoringTest do
  use ExUnit.Case, async: false

  setup do
    path =
      Path.join(System.tmp_dir!(), "zaik-skill-authoring-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    %{path: path}
  end

  test "proposal is inert until exact operator confirmation validates and writes it", %{
    path: path
  } do
    definition = valid_definition()

    assert {:ok, proposal} =
             Zaik.SkillAuthoring.propose(definition, "operator-1", paths: [path])

    assert proposal.type == "home_skill_authoring"
    assert proposal.status == "pending"
    assert proposal.action["kind"] == "install_validated_home_skill"
    assert Path.wildcard(Path.join(path, "*.md")) == []

    assert {:ok, installed} =
             Zaik.SkillAuthoring.confirm(proposal.id, "operator-2", paths: [path])

    assert installed.proposal_id == proposal.id
    assert installed.approved_by == "operator-2"
    assert File.exists?(installed.path)

    assert [skill] = Zaik.SkillStore.list(paths: [path])
    assert skill.name == "nursery_quiet_time"
    assert skill.contract.goal_id == "nursery_quiet_time"
    assert skill.contract.required_observations == ["capability.cover"]
    assert skill.contract.allowed_tools == ["get_home_state"]
    assert skill.text =~ "proposal_id: #{proposal.id}"
    assert skill.text =~ "approved_by: operator-2"

    assert {:ok, repeated} =
             Zaik.SkillAuthoring.confirm(proposal.id, "operator-2", paths: [path])

    assert repeated.path == installed.path
    assert length(Path.wildcard(Path.join(path, "*.md"))) == 1
  end

  test "rejected or invalid proposals cannot write skills", %{path: path} do
    assert {:ok, rejected} =
             Zaik.SkillAuthoring.propose(valid_definition(), "operator-1", paths: [path])

    assert {:ok, _proposal} = Zaik.Proposals.reject(rejected.id, "operator-2")

    assert {:error, :skill_proposal_rejected} =
             Zaik.SkillAuthoring.confirm(rejected.id, "operator-2", paths: [path])

    invalid = put_in(valid_definition(), [:contract, :allowed_tools], ["unregistered_tool"])

    assert {:error, {:unknown_skill_tool, "unregistered_tool"}} =
             Zaik.SkillAuthoring.propose(invalid, "operator-1", paths: [path])

    assert Path.wildcard(Path.join(path, "*.md")) == []
  end

  test "direct unvalidated writes are rejected", %{path: path} do
    assert_raise ArgumentError, ~r/unvalidated direct skill writes are prohibited/, fn ->
      apply(Zaik.SkillStore, :ensure_home_skill!, ["unsafe", "do anything", [paths: [path]]])
    end

    assert {:error, :not_found} =
             Zaik.SkillStore.persist_validated(
               valid_definition(),
               %{proposal_id: "proposal-does-not-exist", approved_by: "operator"},
               paths: [path]
             )

    assert Path.wildcard(Path.join(path, "*.md")) == []
  end

  defp valid_definition do
    %{
      name: "nursery_quiet_time",
      domain: "home",
      risk: "low",
      triggers: ["start nursery quiet time", "the nursery needs quiet time"],
      body: "Gather current cover state and explain the validated quiet-time goal.",
      contract: %{
        schema_version: 1,
        goal_id: "nursery_quiet_time",
        scope: "nursery",
        required_observations: ["capability.cover"],
        preferences: ["reduce outside light"],
        constraints: ["never bypass action verification"],
        allowed_tools: ["get_home_state"],
        risk_ceiling: "low",
        missing_data_policy: "block"
      }
    }
  end
end

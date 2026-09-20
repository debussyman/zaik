defmodule Zaik.SkillAuthoring do
  @moduledoc """
  Proposal/confirmation boundary for model-authored home skills.

  Proposal creation validates and fingerprints inert skill data but never writes
  a skill file. Confirmation re-loads the immutable proposal, validates it again,
  requires an operator identity, and performs the only supported skill write.
  """

  @schema_version 1
  @risk_rank %{"none" => 0, "low" => 1, "medium" => 2, "high" => 3}

  def propose(skill, created_by, opts \\ [])

  def propose(skill, created_by, opts) when is_map(skill) do
    with {:ok, created_by} <- non_empty(created_by, :missing_created_by),
         {:ok, normalized} <- validate(skill, opts) do
      fingerprint = fingerprint(normalized)

      Zaik.Proposals.create(%{
        type: :home_skill_authoring,
        title: "Install home skill #{normalized.name}",
        body:
          "Review validated goal #{normalized.contract.goal_id} for scope #{normalized.contract.scope}.",
        action: %{
          kind: "install_validated_home_skill",
          schema_version: @schema_version,
          skill: normalized,
          definition_fingerprint: fingerprint
        },
        metadata: %{
          definition_fingerprint: fingerprint,
          goal_id: normalized.contract.goal_id,
          scope: normalized.contract.scope
        },
        created_by: created_by
      })
    end
  end

  def propose(_skill, _created_by, _opts), do: {:error, :invalid_skill_definition}

  def confirm(proposal_id, approved_by, opts \\ [])

  def confirm(proposal_id, approved_by, opts) when is_binary(proposal_id) do
    with {:ok, approved_by} <- non_empty(approved_by, :missing_approved_by),
         {:ok, proposal} <- Zaik.Proposals.get(proposal_id),
         :ok <- validate_proposal_type(proposal),
         {:ok, proposal} <- ensure_approved(proposal, approved_by),
         {:ok, skill, expected_fingerprint} <- proposal_skill(proposal),
         {:ok, normalized} <- validate(skill, opts),
         true <- fingerprint(normalized) == expected_fingerprint do
      Zaik.SkillStore.persist_validated(
        normalized,
        %{proposal_id: proposal.id, approved_by: proposal.decided_by || approved_by},
        opts
      )
    else
      false -> {:error, :skill_proposal_fingerprint_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def confirm(_proposal_id, _approved_by, _opts), do: {:error, :invalid_skill_proposal_id}

  def validate(skill, opts \\ [])

  def validate(skill, opts) when is_map(skill) do
    with {:ok, name} <- bounded_string(value(skill, :name), :missing_skill_name, 100),
         :ok <- safe_skill_name(name),
         {:ok, domain} <- bounded_string(value(skill, :domain), :missing_skill_domain, 40),
         :ok <- home_domain(domain),
         {:ok, risk} <- risk(value(skill, :risk)),
         {:ok, triggers} <- bounded_strings(value(skill, :triggers), :missing_skill_triggers),
         {:ok, body} <- bounded_body(value(skill, :body)),
         {:ok, contract} <- Zaik.Home.GoalContract.new(skill),
         :ok <- validate_contract_lists(contract),
         :ok <- validate_tools(contract, opts),
         :ok <- validate_skill_risk(risk, contract.risk_ceiling) do
      {:ok,
       %{
         name: name,
         domain: domain,
         risk: risk,
         triggers: triggers,
         body: body,
         contract: Map.from_struct(contract)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(_skill, _opts), do: {:error, :invalid_skill_definition}

  @doc false
  def authorize_persistence(skill, proposal_id, approved_by) do
    with {:ok, proposal} <- Zaik.Proposals.get(proposal_id),
         :ok <- validate_proposal_type(proposal),
         "approved" <- proposal.status,
         ^approved_by <- proposal.decided_by,
         {:ok, _proposal_skill, expected_fingerprint} <- proposal_skill(proposal),
         true <- fingerprint(skill) == expected_fingerprint do
      :ok
    else
      nil -> {:error, :skill_proposal_missing_operator_identity}
      false -> {:error, :skill_proposal_fingerprint_mismatch}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :skill_persistence_not_authorized}
    end
  end

  def render(skill, proposal_id, approved_by) do
    contract = skill.contract

    """
    ---
    name: #{scalar(skill.name)}
    domain: home
    risk: #{skill.risk}
    schema_version: #{contract.schema_version}
    goal_id: #{scalar(contract.goal_id)}
    scope: #{scalar(contract.scope)}
    risk_ceiling: #{contract.risk_ceiling}
    missing_data_policy: #{contract.missing_data_policy}
    proposal_id: #{scalar(proposal_id)}
    approved_by: #{scalar(approved_by)}
    required_observations:
    #{render_list(contract.required_observations)}
    preferences:
    #{render_list(contract.preferences)}
    constraints:
    #{render_list(contract.constraints)}
    allowed_tools:
    #{render_list(contract.allowed_tools)}
    triggers:
    #{render_list(skill.triggers)}
    ---

    #{String.trim(skill.body)}
    """
  end

  defp safe_skill_name(name) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9 _-]*$/, name),
      do: :ok,
      else: {:error, :invalid_skill_name}
  end

  defp home_domain("home"), do: :ok
  defp home_domain(_domain), do: {:error, :unsupported_skill_domain}

  defp validate_skill_risk(risk, ceiling) do
    if @risk_rank[risk] <= @risk_rank[ceiling],
      do: :ok,
      else: {:error, :skill_risk_exceeds_contract_ceiling}
  end

  defp validate_tools(contract, opts) do
    registry_opts = Keyword.get(opts, :tool_registry_opts, [])
    ceiling = @risk_rank[contract.risk_ceiling]

    contract.allowed_tools
    |> Enum.reduce_while(:ok, fn tool, :ok ->
      case Zaik.Tools.Registry.fetch(tool, registry_opts) do
        {:ok, %{descriptor: descriptor}} ->
          if @risk_rank[to_string(descriptor.risk)] <= ceiling,
            do: {:cont, :ok},
            else: {:halt, {:error, {:skill_tool_risk_exceeded, tool, descriptor.risk}}}

        {:error, _reason} ->
          {:halt, {:error, {:unknown_skill_tool, tool}}}
      end
    end)
  end

  defp validate_contract_lists(contract) do
    lists = [
      contract.required_observations,
      contract.preferences,
      contract.constraints,
      contract.allowed_tools
    ]

    if Enum.all?(lists, fn values ->
         length(values) <= 32 and
           Enum.all?(values, &(byte_size(&1) <= 500 and not String.contains?(&1, ["\r", "\n"])))
       end) do
      :ok
    else
      {:error, :skill_contract_values_too_large}
    end
  end

  defp proposal_skill(proposal) do
    action = proposal.action || %{}

    with "install_validated_home_skill" <- value(action, :kind),
         @schema_version <- value(action, :schema_version),
         skill when is_map(skill) <- value(action, :skill),
         fingerprint when is_binary(fingerprint) <- value(action, :definition_fingerprint) do
      {:ok, skill, fingerprint}
    else
      _ -> {:error, :invalid_skill_proposal_action}
    end
  end

  defp validate_proposal_type(%{type: "home_skill_authoring"}), do: :ok
  defp validate_proposal_type(%{type: :home_skill_authoring}), do: :ok
  defp validate_proposal_type(_proposal), do: {:error, :not_a_skill_proposal}

  defp ensure_approved(%{status: "pending"} = proposal, approved_by) do
    Zaik.Proposals.approve(proposal.id, approved_by)
  end

  defp ensure_approved(%{status: "approved", decided_by: decided_by} = proposal, _approved_by)
       when is_binary(decided_by) and decided_by != "",
       do: {:ok, proposal}

  defp ensure_approved(%{status: "approved"}, _approved_by),
    do: {:error, :skill_proposal_missing_operator_identity}

  defp ensure_approved(%{status: "rejected"}, _approved_by),
    do: {:error, :skill_proposal_rejected}

  defp ensure_approved(_proposal, _approved_by), do: {:error, :invalid_skill_proposal_status}

  defp bounded_strings(values, error) do
    values = List.wrap(values)

    cond do
      values == [] ->
        {:error, error}

      length(values) > 32 ->
        {:error, :too_many_skill_values}

      true ->
        normalized = values |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1)

        if Enum.any?(
             normalized,
             &(&1 == "" or byte_size(&1) > 500 or String.contains?(&1, ["\r", "\n"]))
           ),
           do: {:error, :invalid_skill_value},
           else: {:ok, Enum.uniq(normalized)}
    end
  end

  defp risk(value) do
    value = value |> to_string() |> String.trim() |> String.downcase()
    if Map.has_key?(@risk_rank, value), do: {:ok, value}, else: {:error, :invalid_skill_risk}
  end

  defp bounded_body(value) do
    with {:ok, value} <- non_empty(value, :missing_skill_body),
         true <- byte_size(value) <= 8_000 do
      {:ok, value}
    else
      false -> {:error, :skill_value_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounded_string(value, error, maximum) do
    with {:ok, value} <- non_empty(value, error),
         true <- byte_size(value) <= maximum and not String.contains?(value, ["\r", "\n"]) do
      {:ok, value}
    else
      false -> {:error, :skill_value_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp non_empty(value, error) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, error}, else: {:ok, value}
  end

  defp non_empty(_value, error), do: {:error, error}

  defp fingerprint(skill) do
    skill
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical(value), do: value

  defp render_list([]), do: ""
  defp render_list(values), do: Enum.map_join(values, "\n", &("  - " <> scalar(&1)))

  defp scalar(value) do
    value
    |> to_string()
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.replace("\"", "'")
    |> String.trim()
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end

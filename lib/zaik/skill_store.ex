defmodule Zaik.SkillStore do
  @moduledoc """
  Filesystem-backed, model-readable Zaik skills.

  Skills are prompt context, not deterministic routines. They teach the house
  agent household semantics and preferred procedures; execution still goes
  through validated tools.
  """

  @default_max_relevant 3

  def config do
    configured = Application.get_env(:zaik, :skills, [])

    %{
      enabled: env_bool("ZAIK_SKILLS_ENABLED", Keyword.get(configured, :enabled, true)),
      paths: configured_paths(configured),
      max_relevant:
        env_integer(
          "ZAIK_MAX_RELEVANT_SKILLS",
          Keyword.get(configured, :max_relevant, @default_max_relevant)
        )
    }
  end

  def list(opts \\ []) do
    cfg = Map.merge(config(), Map.new(opts))

    if cfg.enabled do
      cfg.paths
      |> Enum.flat_map(&Path.wildcard(Path.join(expand_path(&1), "*.md")))
      |> Enum.map(&read_skill/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&String.downcase(&1.name))
    else
      []
    end
  end

  def relevant(text, opts \\ [])

  def relevant(text, opts) when is_binary(text) do
    cfg = Map.merge(config(), Map.new(opts))
    normalized = normalize(text)

    list(opts)
    |> Enum.map(&{score_skill(&1, normalized), &1})
    |> Enum.filter(fn {score, skill} -> score >= minimum_relevance_score(skill) end)
    |> Enum.sort_by(fn {score, skill} -> {-score, String.downcase(skill.name)} end)
    |> Enum.take(cfg.max_relevant)
    |> Enum.map(fn {_score, skill} -> skill end)
  end

  def relevant(_text, _opts), do: []

  def format_for_prompt(skills) when is_list(skills) do
    case skills do
      [] -> "No relevant skills found."
      skills -> Enum.map_join(skills, "\n\n---\n\n", &format_skill/1)
    end
  end

  @deprecated "Direct skill writes are prohibited; use Zaik.SkillAuthoring proposals"
  def ensure_home_skill!(_name, _contents, _opts \\ []) do
    raise ArgumentError,
          "unvalidated direct skill writes are prohibited; use Zaik.SkillAuthoring.propose/3 and confirm/3"
  end

  @doc false
  def persist_validated(skill, audit, opts \\ [])

  def persist_validated(skill, audit, opts) when is_map(skill) and is_map(audit) do
    with {:ok, normalized} <- Zaik.SkillAuthoring.validate(skill, opts),
         {:ok, proposal_id} <- required_audit(audit, :proposal_id),
         {:ok, approved_by} <- required_audit(audit, :approved_by),
         :ok <- Zaik.SkillAuthoring.authorize_persistence(normalized, proposal_id, approved_by) do
      cfg = Map.merge(config(), Map.new(opts))
      [path | _] = cfg.paths
      dir = expand_path(path)
      File.mkdir_p!(dir)
      file = Path.join(dir, safe_filename(normalized.name) <> ".md")
      temporary = file <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
      contents = Zaik.SkillAuthoring.render(normalized, proposal_id, approved_by)

      with :ok <- File.write(temporary, contents, [:binary, :exclusive]),
           :ok <- File.rename(temporary, file) do
        {:ok,
         %{path: file, skill: normalized, proposal_id: proposal_id, approved_by: approved_by}}
      else
        {:error, reason} ->
          File.rm(temporary)
          {:error, {:skill_write_failed, reason}}
      end
    end
  end

  def persist_validated(_skill, _audit, _opts), do: {:error, :invalid_skill_definition}

  defp read_skill(path) do
    with {:ok, contents} <- File.read(path) do
      {metadata, body} = parse_frontmatter(contents)

      skill = %{
        path: path,
        name: metadata["name"] || path |> Path.basename(".md") |> String.replace("_", " "),
        domain: metadata["domain"],
        risk: metadata["risk"],
        allowed_tools: parse_list(metadata["allowed_tools"]),
        triggers: parse_list(metadata["triggers"]),
        body: String.trim(body),
        text: String.trim(contents)
      }

      Map.put(skill, :contract, goal_contract_metadata(metadata, skill))
    else
      _ -> nil
    end
  end

  defp parse_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [frontmatter, body] -> {parse_yamlish(frontmatter), body}
      _ -> {%{}, rest}
    end
  end

  defp parse_frontmatter(contents), do: {%{}, contents}

  defp parse_yamlish(contents) do
    contents
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, fn line, {acc, current_key} ->
      cond do
        match = Regex.run(~r/^([A-Za-z_][\w-]*):\s*(.*?)\s*$/, line) ->
          [_, key, value] = match
          value = strip_quotes(value)
          {Map.put(acc, key, value), key}

        match = Regex.run(~r/^\s*-\s*(.*?)\s*$/, line) ->
          [_, value] = match

          if current_key do
            values = acc |> Map.get(current_key, []) |> List.wrap()
            {Map.put(acc, current_key, values ++ [strip_quotes(value)]), current_key}
          else
            {acc, current_key}
          end

        true ->
          {acc, current_key}
      end
    end)
    |> elem(0)
  end

  defp goal_contract_metadata(metadata, skill) do
    if metadata["goal_id"] do
      %{
        schema_version: parse_integer(metadata["schema_version"]),
        goal_id: metadata["goal_id"],
        scope: metadata["scope"],
        required_observations: parse_list(metadata["required_observations"]),
        preferences: parse_list(metadata["preferences"]),
        constraints: parse_list(metadata["constraints"]),
        allowed_tools: skill.allowed_tools,
        risk_ceiling: metadata["risk_ceiling"] || skill.risk,
        missing_data_policy: metadata["missing_data_policy"] || "block"
      }
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp parse_list(nil), do: []

  defp parse_list(value) when is_list(value) do
    value |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_list(""), do: []

  defp parse_list(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",", trim: true)
    |> Enum.map(&strip_quotes/1)
  end

  defp format_skill(skill) do
    contract =
      case skill.contract do
        nil ->
          ""

        value ->
          """
          goal_schema_version: #{value.schema_version}
          goal_id: #{value.goal_id}
          scope: #{value.scope}
          required_observations: #{Enum.join(value.required_observations, ", ")}
          preferences: #{Enum.join(value.preferences, " | ")}
          constraints: #{Enum.join(value.constraints, " | ")}
          risk_ceiling: #{value.risk_ceiling}
          missing_data_policy: #{value.missing_data_policy}
          """
      end

    """
    SKILL: #{skill.name}
    domain: #{skill.domain || "unknown"}
    risk: #{skill.risk || "unknown"}
    allowed_tools: #{Enum.join(skill.allowed_tools, ", ")}
    #{contract}
    #{skill.body}
    """
    |> String.trim()
  end

  defp minimum_relevance_score(%{contract: contract}) when is_map(contract), do: 2
  defp minimum_relevance_score(_skill), do: 1

  defp score_skill(skill, normalized_text) do
    contract = skill.contract || %{}

    searchable =
      [
        skill.name,
        skill.domain,
        skill.body,
        Map.get(contract, :goal_id),
        Map.get(contract, :scope)
      ] ++
        skill.triggers ++
        Map.get(contract, :preferences, []) ++ Map.get(contract, :constraints, [])

    skill_terms =
      searchable
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(fn value ->
        normalized = normalize(value)
        [normalized | String.split(normalized, " ", trim: true)]
      end)
      |> Enum.reject(&(&1 == "" or byte_size(&1) < 3 or stop_word?(&1)))
      |> Enum.uniq()

    Enum.count(skill_terms, fn term ->
      Regex.match?(~r/(^|\s)#{Regex.escape(term)}(\s|$)/, normalized_text)
    end)
  end

  defp stop_word?(word),
    do:
      word in ~w(the and for with when you your into this that from room home skill use user asks expected plan)

  defp required_audit(audit, key) do
    case Map.get(audit, key) || Map.get(audit, to_string(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, {:missing_skill_audit, key}}, else: {:ok, value}

      _ ->
        {:error, {:missing_skill_audit, key}}
    end
  end

  defp safe_filename(name) do
    name
    |> normalize()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/['’]/, "")
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp strip_quotes(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp configured_paths(configured) do
    env_paths = System.get_env("ZAIK_SKILLS_PATHS")

    cond do
      is_binary(env_paths) and String.trim(env_paths) != "" ->
        String.split(env_paths, ":", trim: true)

      paths = Keyword.get(configured, :paths) ->
        List.wrap(paths)

      true ->
        ["~/.zaik/home/skills"]
    end
  end

  defp expand_path("~" <> rest), do: Path.expand(System.user_home!() <> rest)
  defp expand_path(path), do: Path.expand(path)

  defp env_bool(name, fallback) do
    case System.get_env(name) do
      nil -> fallback
      value -> value |> String.downcase() |> then(&(&1 in ["1", "true", "yes", "on"]))
    end
  end

  defp env_integer(name, fallback) do
    case System.get_env(name) do
      nil ->
        fallback

      value ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> fallback
        end
    end
  end
end

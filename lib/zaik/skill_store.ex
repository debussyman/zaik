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
    |> Enum.filter(fn {score, _skill} -> score > 0 end)
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

  def ensure_home_skill!(name, contents, opts \\ [])
      when is_binary(name) and is_binary(contents) do
    cfg = Map.merge(config(), Map.new(opts))
    [path | _] = cfg.paths
    dir = expand_path(path)
    File.mkdir_p!(dir)
    file = Path.join(dir, safe_filename(name) <> ".md")
    File.write!(file, contents)
    file
  end

  defp read_skill(path) do
    with {:ok, contents} <- File.read(path) do
      {metadata, body} = parse_frontmatter(contents)

      %{
        path: path,
        name: metadata["name"] || path |> Path.basename(".md") |> String.replace("_", " "),
        domain: metadata["domain"],
        risk: metadata["risk"],
        allowed_tools: parse_list(metadata["allowed_tools"]),
        triggers: parse_list(metadata["triggers"]),
        body: String.trim(body),
        text: String.trim(contents)
      }
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
    """
    SKILL: #{skill.name}
    domain: #{skill.domain || "unknown"}
    risk: #{skill.risk || "unknown"}
    allowed_tools: #{Enum.join(skill.allowed_tools, ", ")}

    #{skill.body}
    """
    |> String.trim()
  end

  defp score_skill(skill, normalized_text) do
    skill_terms =
      [skill.name, skill.domain | skill.triggers]
      |> Enum.concat(String.split(skill.body, ~r/[^A-Za-z0-9']+/, trim: true))
      |> Enum.map(&normalize/1)
      |> Enum.reject(&(&1 == "" or byte_size(&1) < 3 or stop_word?(&1)))
      |> Enum.uniq()

    Enum.count(skill_terms, fn term ->
      Regex.match?(~r/(^|\s)#{Regex.escape(term)}(\s|$)/, normalized_text)
    end)
  end

  defp stop_word?(word),
    do:
      word in ~w(the and for with when you your into this that from room home skill use user asks expected plan)

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

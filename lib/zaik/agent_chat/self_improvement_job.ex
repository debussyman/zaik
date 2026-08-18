defmodule Zaik.AgentChat.SelfImprovementJob do
  @moduledoc """
  Daily AgentChat eval comparison job.

  The job compares a small candidate model against a reference model on the live
  AgentChat eval suite. When the candidate fails cases that the reference passes,
  it creates a pending proposal for prompt/eval tuning. It never rewrites prompts
  or applies code changes by itself.
  """

  require Logger

  def config do
    configured = Application.get_env(:zaik, :self_improvement, [])

    %{
      candidate_model:
        System.get_env("ZAIK_SELF_IMPROVEMENT_CANDIDATE_MODEL") ||
          Keyword.get(configured, :candidate_model, "qwen3:4b-instruct"),
      reference_model:
        System.get_env("ZAIK_SELF_IMPROVEMENT_REFERENCE_MODEL") ||
          Keyword.get(configured, :reference_model, "qwen3-coder:30b"),
      timeout_ms:
        env_integer("ZAIK_SELF_IMPROVEMENT_TIMEOUT_MS") ||
          Keyword.get(configured, :timeout_ms, 120_000),
      notify_telegram_chat_id:
        System.get_env("ZAIK_SELF_IMPROVEMENT_NOTIFY_TELEGRAM_CHAT_ID") ||
          Keyword.get(configured, :notify_telegram_chat_id)
    }
  end

  def run(opts \\ []) do
    cfg = Map.merge(config(), Map.new(opts))

    Logger.info(
      "AgentChat self-improvement eval: candidate=#{cfg.candidate_model} reference=#{cfg.reference_model}"
    )

    candidate = Zaik.AgentChat.Evals.run(model: cfg.candidate_model, timeout_ms: cfg.timeout_ms)

    if candidate.failed == 0 do
      {:ok, %{candidate: cfg.candidate_model, failed: 0, proposal_created?: false}}
    else
      reference = Zaik.AgentChat.Evals.run(model: cfg.reference_model, timeout_ms: cfg.timeout_ms)
      create_proposal_if_reference_helps(candidate, reference, cfg)
    end
  end

  defp create_proposal_if_reference_helps(candidate, reference, cfg) do
    candidate_failures = Map.new(Enum.reject(candidate.results, & &1.passed?), &{&1.name, &1})
    reference_passes = Map.new(Enum.filter(reference.results, & &1.passed?), &{&1.name, &1})

    improvable_names =
      candidate_failures
      |> Map.keys()
      |> Enum.filter(&Map.has_key?(reference_passes, &1))
      |> Enum.sort()

    if improvable_names == [] do
      {:ok,
       %{
         candidate: cfg.candidate_model,
         reference: cfg.reference_model,
         candidate_failed: candidate.failed,
         reference_passed: reference.passed,
         proposal_created?: false
       }}
    else
      body = proposal_body(candidate, reference, improvable_names, cfg)

      attrs = %{
        type: :agent_chat_prompt_tuning,
        title: "Review AgentChat prompt tuning for #{cfg.candidate_model}",
        body: body,
        action: %{
          kind: "agent_chat_prompt_tuning_review",
          target_files: [
            "lib/zaik/agent_chat/prompts.ex",
            "lib/zaik/agent_chat/evals.ex"
          ],
          candidate_model: cfg.candidate_model,
          reference_model: cfg.reference_model,
          eval_names: improvable_names
        },
        metadata: %{
          candidate_summary: Map.take(candidate, [:passed, :failed]),
          reference_summary: Map.take(reference, [:passed, :failed]),
          generated_by: inspect(__MODULE__)
        },
        created_by: inspect(__MODULE__)
      }

      with {:ok, proposal} <- Zaik.Proposals.create(attrs) do
        maybe_notify(proposal, cfg)

        {:ok,
         %{
           candidate: cfg.candidate_model,
           reference: cfg.reference_model,
           candidate_failed: candidate.failed,
           reference_passed: reference.passed,
           improvable: improvable_names,
           proposal_id: proposal.id,
           proposal_created?: true
         }}
      end
    end
  end

  defp proposal_body(candidate, reference, improvable_names, cfg) do
    failures =
      improvable_names
      |> Enum.map(fn name ->
        result = Enum.find(candidate.results, &(&1.name == name))

        failed_checks =
          result.checks
          |> Enum.reject(& &1.passed?)
          |> Enum.map_join(", ", &to_string(&1.name))

        tool_calls = Enum.map(result.tool_calls, & &1.query)

        "- #{name}: failed checks=#{failed_checks}; tool_calls=#{inspect(tool_calls, limit: 3)}"
      end)
      |> Enum.join("\n")

    """
    Zaik found AgentChat eval cases where #{cfg.candidate_model} failed and #{cfg.reference_model} passed.

    Candidate summary: #{candidate.passed} passed, #{candidate.failed} failed.
    Reference summary: #{reference.passed} passed, #{reference.failed} failed.

    Improvable cases:
    #{failures}

    Proposed next action for a human/coding agent:
    1. Add or refine failing eval coverage in lib/zaik/agent_chat/evals.ex.
    2. Adjust domain prompts in lib/zaik/agent_chat/prompts.ex.
    3. Run the full eval suite for #{cfg.candidate_model} and the regular test suite.
    4. Apply only after explicit approval.
    """
    |> String.trim()
  end

  defp maybe_notify(%{id: id, title: title}, %{notify_telegram_chat_id: chat_id})
       when is_binary(chat_id) and chat_id != "" do
    text =
      "Zaik proposal #{id}: #{title}\nSay `proposal #{id}` to inspect, `approve #{id}` to approve, or `reject #{id}` to reject."

    case Zaik.Messaging.TelegramClient.send_message(chat_id, text) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("Proposal notification failed: #{inspect(reason)}")
    end
  end

  defp maybe_notify(_proposal, _cfg), do: :ok

  defp env_integer(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> nil
        end
    end
  end
end

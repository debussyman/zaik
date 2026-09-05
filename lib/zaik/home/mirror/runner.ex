defmodule Zaik.Home.Mirror.Runner do
  @moduledoc """
  Runs code or AgentChat against an isolated mirror and returns semantic checks.
  """

  def run(scenario, fun, opts \\ []) when is_function(fun, 2) do
    with {:ok, mirror} <- Zaik.Home.Mirror.start(scenario) do
      try do
        context = Zaik.Home.Mirror.context(mirror, Keyword.get(opts, :context, %{}))
        result = fun.(mirror, context)
        settle_ms = Keyword.get(opts, :settle_ms, 0)
        if settle_ms > 0, do: Process.sleep(settle_ms)

        {:ok,
         %{
           result: result,
           report: Zaik.Home.Mirror.Assertions.evaluate(mirror)
         }}
      after
        Zaik.Home.Mirror.stop(mirror)
      end
    end
  end

  def run_agent(scenario, prompt, opts \\ []) when is_binary(prompt) do
    agent_opts = Keyword.get(opts, :agent_opts, [])

    run(
      scenario,
      fn _mirror, context ->
        Zaik.AgentChat.respond(prompt, context, agent_opts)
      end,
      opts
    )
  end
end

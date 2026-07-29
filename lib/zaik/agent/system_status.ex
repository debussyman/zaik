defmodule Zaik.Agent.SystemStatus do
  @moduledoc """
  Safe system inspection task agent.

  This intentionally avoids shell execution and uses Erlang VM APIs only.
  """

  use Zaik.Agent.TaskRunner

  @impl true
  def run_task(_task, state) do
    {uptime_ms, _since_last_call_ms} = :erlang.statistics(:wall_clock)

    result = %{
      node: inspect(Node.self()),
      uptime_ms: uptime_ms,
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      schedulers_online: :erlang.system_info(:schedulers_online),
      otp_release: :erlang.system_info(:otp_release) |> List.to_string(),
      memory: :erlang.memory() |> Map.new()
    }

    {:ok, result, state}
  end
end

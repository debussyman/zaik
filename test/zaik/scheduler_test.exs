defmodule Zaik.SchedulerTest do
  use ExUnit.Case, async: true

  defmodule TestJob do
    def run(opts),
      do: send(Keyword.fetch!(opts, :test_pid), {:job_ran, Keyword.get(opts, :value)})
  end

  test "daily delay picks the next matching UTC time" do
    now = DateTime.new!(~D[2026-08-18], ~T[02:00:00], "Etc/UTC")
    assert Zaik.Scheduler.next_delay_ms({:daily, "03:00:00"}, now) == 3_600_000

    now = DateTime.new!(~D[2026-08-18], ~T[04:00:00], "Etc/UTC")
    assert Zaik.Scheduler.next_delay_ms({:daily, "03:00:00"}, now) == 82_800_000
  end

  test "run_now executes configured job even when recurring schedule is disabled" do
    name = String.to_atom("scheduler_#{System.unique_integer([:positive])}")

    {:ok, scheduler} =
      start_supervised(
        {Zaik.Scheduler,
         name: name,
         jobs: [
           %{
             name: :test_job,
             module: TestJob,
             schedule: {:daily, "03:00:00"},
             enabled: false,
             opts: [test_pid: self(), value: 42]
           }
         ]}
      )

    assert Zaik.Scheduler.run_now(:test_job, scheduler) == :ok
    assert_receive {:job_ran, 42}, 1_000
  end
end

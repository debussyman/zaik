# Zaik Dynamic Agent Dispatcher Implementation Spec

## Audience

This spec is intended for a coding agent/model implementing the next vertical slice of Zaik.

The previous slice already added:

- `Zaik.Task`
- `Zaik.TaskStore`
- `Zaik.TaskQueue`
- `Zaik.Session`
- `Zaik.SessionStore`
- `Zaik.MemoryStore`
- `Zaik.ContextBuilder`

Current tests pass with:

```bash
nix develop -c mix test
```

Your job is to implement dynamic task execution: start an agent for a queued task, supervise it, collect the result, and expose public task submission/await APIs.

---

## Goals

Implement a minimal working task harness that supports:

1. `Zaik.submit_task/3`
2. task insertion into `Zaik.TaskStore`
3. optional task/session memory entries
4. priority queue enqueue
5. dispatcher dequeue
6. dynamic task-agent startup
7. task execution through a task-runner behaviour
8. result/failure collection
9. timeout handling
10. `Zaik.await_task/2`
11. end-to-end `:echo` task

Target example:

```elixir
{:ok, task_id} = Zaik.submit_task(:echo, %{message: "hello"}, priority: 50)
{:ok, result} = Zaik.await_task(task_id, 5_000)

assert result == %{message: "hello"}
```

---

## Constraints

- Keep the implementation small and idiomatic OTP.
- Do not implement LLMs yet.
- Do not implement WhatsApp/Signal yet.
- Do not implement a watchdog yet.
- Do not add databases.
- Preserve all existing tests.
- Add tests for all new behavior.
- Run `mix format` and `mix test` before finishing.
- Use `nix develop -c mix test` if `mix` is not available directly.

---

## Modules to Add

## 1. `Zaik.Agent.DynamicSupervisor`

A `DynamicSupervisor` for task-specific agents.

File:

```text
lib/zaik/agent/dynamic_supervisor.ex
```

Responsibilities:

- start task agents dynamically
- isolate task-agent crashes
- use `restart: :temporary`

API:

```elixir
Zaik.Agent.DynamicSupervisor.start_task_agent(task, agent_module, dispatcher \\ Zaik.Dispatcher)
Zaik.Agent.DynamicSupervisor.stop_agent(pid)
```

Expected child spec shape:

```elixir
%{
  id: {agent_module, task.id},
  start: {agent_module, :start_link, [[task: task, dispatcher: dispatcher, name: via_name(task.id)]]},
  restart: :temporary,
  type: :worker
}
```

Use registry names:

```elixir
{:via, Registry, {Zaik.Agent.Registry, {:task_agent, task.id}}}
```

---

## 2. `Zaik.Agent.Registry`

Add this to the application supervision tree using Elixir's built-in `Registry`:

```elixir
{Registry, keys: :unique, name: Zaik.Agent.Registry}
```

It should be supervised before `Zaik.Agent.DynamicSupervisor` and `Zaik.Dispatcher`.

---

## 3. `Zaik.Agent.TaskRunner`

A behaviour/macro for one-shot task agents.

File:

```text
lib/zaik/agent/task_runner.ex
```

Behaviour callback:

```elixir
@callback run_task(task :: Zaik.Task.t(), state :: term()) ::
            {:ok, result :: term(), new_state :: term()}
            | {:error, reason :: term(), new_state :: term()}
```

Macro should provide a GenServer implementation.

Expected agent lifecycle:

1. Start with opts including `:task` and `:dispatcher`.
2. Register under the provided `:name` if present.
3. In `init/1`, store task and dispatcher.
4. Trigger execution after init, e.g. `send(self(), :run_task)`.
5. On `:run_task`, call `run_task(task, state)`.
6. Send result to dispatcher:

```elixir
send(dispatcher, {:task_complete, task.id, result})
```

or:

```elixir
send(dispatcher, {:task_failed, task.id, reason})
```

7. Stop normally after reporting:

```elixir
{:stop, :normal, new_state}
```

Default callbacks:

```elixir
def agent_init(_task, _opts), do: {:ok, %{}}
```

Optional callback:

```elixir
@callback agent_init(task :: Zaik.Task.t(), opts :: keyword()) :: {:ok, state} | {:error, reason}
```

If you keep it simpler, a default empty state is fine.

---

## 4. `Zaik.Agent.Echo`

A simple task agent for end-to-end tests.

File:

```text
lib/zaik/agent/echo.ex
```

Implementation:

```elixir
defmodule Zaik.Agent.Echo do
  use Zaik.Agent.TaskRunner

  @impl true
  def run_task(task, state) do
    {:ok, task.payload, state}
  end
end
```

---

## 5. `Zaik.TaskResolver`

Maps task type to agent module.

File:

```text
lib/zaik/task_resolver.ex
```

API:

```elixir
Zaik.TaskResolver.resolve(task_or_type)
```

Initial mapping:

```elixir
:echo -> Zaik.Agent.Echo
```

Return shapes:

```elixir
{:ok, Zaik.Agent.Echo}
{:error, :unknown_task_type}
```

---

## 6. `Zaik.Dispatcher`

A GenServer that pulls tasks from the queue and runs them.

File:

```text
lib/zaik/dispatcher.ex
```

Responsibilities:

- dequeue tasks from `Zaik.TaskQueue`
- fetch full task from `Zaik.TaskStore`
- resolve task type through `Zaik.TaskResolver`
- start agent through `Zaik.Agent.DynamicSupervisor`
- monitor agent with `Process.monitor/1`
- schedule timeout with `Process.send_after/3`
- handle completion/failure messages
- update `Zaik.TaskStore`
- append task results to session memory if `task.session_id` is present
- enforce `max_concurrency`

Start options:

```elixir
Zaik.Dispatcher.start_link(max_concurrency: 4)
```

Public API:

```elixir
Zaik.Dispatcher.dispatch_now()
Zaik.Dispatcher.state()
```

State shape:

```elixir
%{
  max_concurrency: 4,
  running: %{
    task_id => %{
      pid: pid,
      monitor_ref: ref,
      timeout_ref: timeout_ref
    }
  }
}
```

### Dispatch flow

When `dispatch_now/0` is called or a task is submitted:

1. If running count >= max concurrency, do nothing.
2. Dequeue from `Zaik.TaskQueue`.
3. If queue empty, do nothing.
4. Fetch task from `Zaik.TaskStore`.
5. Resolve task type.
6. If unknown type: mark task failed.
7. Start task agent.
8. Monitor pid.
9. Schedule timeout.
10. Mark task running in `Zaik.TaskStore`.
11. Continue dispatching until capacity is full or queue is empty.

### Completion handling

Handle:

```elixir
{:task_complete, task_id, result}
```

Expected behavior:

- ignore if task is no longer running
- cancel timeout
- demonitor process
- mark task succeeded
- append `task_result` to `Zaik.MemoryStore` if session-backed
- remove from dispatcher running map
- dispatch next queued task

### Failure handling

Handle:

```elixir
{:task_failed, task_id, reason}
```

Expected behavior:

- cancel timeout
- demonitor process
- mark failed or retry if retries remain
- remove from running map
- dispatch next queued task

Retry can be minimal for this slice:

- If `task.attempts < task.max_retries`, increment attempts, mark queued, update store, enqueue again.
- Else mark failed.

### Agent crash handling

Handle monitor messages:

```elixir
{:DOWN, ref, :process, pid, reason}
```

Expected behavior:

- if reason is `:normal` and task was already completed, ignore
- otherwise mark task failed or retry
- cancel timeout
- cleanup running state
- dispatch next queued task

### Timeout handling

Handle:

```elixir
{:task_timeout, task_id}
```

Expected behavior:

- if task is not running, ignore stale timeout
- stop agent if still alive
- mark timed out or retry
- cleanup running state
- dispatch next queued task

---

## Application Supervision Tree

Update `lib/zaik/application.ex` to include the new components.

Recommended order:

```elixir
children = [
  Zaik.Clock,
  Zaik.TaskStore,
  Zaik.SessionStore,
  Zaik.TaskQueue,
  {Registry, keys: :unique, name: Zaik.Agent.Registry},
  Zaik.Agent.DynamicSupervisor,
  Zaik.Dispatcher,
  Zaik.Agent.Supervisor
]
```

It is acceptable to leave the existing static `Zaik.Agent.Supervisor`/`HelloWorld` in place for now.

---

## Public API Updates

Update `lib/zaik.ex`.

Add:

```elixir
Zaik.submit_task(type, payload, opts \\ [])
Zaik.await_task(task_id, timeout \\ 60_000)
Zaik.cancel_task(task_id)
```

### `submit_task/3`

Expected behavior:

1. Create task with `Zaik.Task.new(type, payload, opts)`.
2. If `session_id` is provided:
   - append task entry through `Zaik.MemoryStore.append_task/2`
   - store returned entry ID in `task.context_entry_id` or `task.parent_entry_id` if useful
3. Insert task into `Zaik.TaskStore`.
4. Enqueue task in `Zaik.TaskQueue`.
5. Trigger `Zaik.Dispatcher.dispatch_now()`.
6. Return `{:ok, task.id}`.

Error cases should return `{:error, reason}`.

### `await_task/2`

Simple polling is acceptable for this slice.

Expected behavior:

- Poll `Zaik.TaskStore.get(task_id)` until terminal status or timeout.
- Return:

```elixir
{:ok, result}
{:error, :timeout}              # caller await timeout only
{:error, :cancelled}
{:error, {:task_failed, reason}}
{:error, :task_timed_out}       # actual task timeout
{:error, :not_found}
```

Do not confuse caller await timeout with task execution timeout.

### `cancel_task/1`

Minimal implementation is acceptable:

- If queued: remove from queue, mark cancelled.
- If running: mark cancelled and let dispatcher timeout/crash cleanup later, or add a dispatcher cancel message if straightforward.
- If terminal: return `{:error, {:already_terminal, status}}`.

---

## Tests to Add

Add tests under `test/zaik/`.

### TaskResolver tests

- resolves `:echo`
- rejects unknown type

### DynamicSupervisor tests

- starts an echo task agent
- agent is registered in `Zaik.Agent.Registry`
- stopping/crashing child does not crash supervisor

### TaskRunner tests

Use test-only agents if needed.

- task runner reports success
- task runner reports failure
- invalid/malformed result is handled if implemented

### Dispatcher tests

- dispatcher dequeues task and starts agent
- echo task completes successfully
- task store is updated to `:succeeded`
- failed task is marked failed
- unknown task type is marked failed
- crashed agent is marked failed
- timed-out task is marked timed out
- dispatcher does not exceed `max_concurrency`
- queued tasks run after capacity opens

### Public API tests

- `Zaik.submit_task(:echo, payload)` returns `{:ok, task_id}`
- `Zaik.await_task(task_id)` returns `{:ok, payload}`
- session-backed task appends `task` and `task_result` entries
- `Zaik.await_task/2` on missing task returns `{:error, :not_found}`
- `Zaik.await_task/2` caller timeout returns `{:error, :timeout}`
- `Zaik.cancel_task/1` cancels queued task

---

## Suggested Test Agents

You may add test-only modules inside test files:

```elixir
defmodule Zaik.TestAgent.Fail do
  use Zaik.Agent.TaskRunner

  def run_task(_task, state), do: {:error, :boom, state}
end
```

```elixir
defmodule Zaik.TestAgent.Slow do
  use Zaik.Agent.TaskRunner

  def run_task(_task, state) do
    Process.sleep(200)
    {:ok, :done, state}
  end
end
```

For resolver-based tests, either extend `Zaik.TaskResolver` with test config support or test the dispatcher using manually enqueued tasks with known task types.

---

## Acceptance Criteria

Implementation is complete when:

```bash
nix develop -c mix format
nix develop -c mix test
```

passes, and this example works:

```elixir
{:ok, task_id} = Zaik.submit_task(:echo, %{message: "hello"})
{:ok, %{message: "hello"}} = Zaik.await_task(task_id, 5_000)
{:ok, task} = Zaik.get_task(task_id)
:succeeded = task.status
```

Also verify a session-backed task:

```elixir
{:ok, session} = Zaik.create_session(scope: :test)
{:ok, task_id} = Zaik.submit_task(:echo, %{message: "hello"}, session_id: session.id)
{:ok, _} = Zaik.await_task(task_id)
{:ok, context} = Zaik.get_session_context(session.id)

# context should include a task entry and a task_result entry
```

---

## Notes / Pitfalls

- Use `Process.monitor/1`; do not rely on scanning the registry for normal crash detection.
- Use `Process.send_after/3` for task timeout.
- Cancel timeout refs on completion/failure/cancellation.
- Use `restart: :temporary` for task agents.
- Avoid blocking the dispatcher for long-running work. The task agent may block; the dispatcher should not.
- Be careful with races: completion and `:DOWN` may both arrive. Terminal task states should not be overwritten.
- Keep retry logic simple and well tested.
- Do not remove or break the existing `HelloWorld` tests.

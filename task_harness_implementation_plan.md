# Zaik Task Harness Implementation Plan

## Goal

Build the core Zaik harness layer that can:

1. Accept a task from an external caller.
2. Assign the task a unique ID and lifecycle state.
3. Add the task to a priority queue.
4. Dispatch the task to an appropriate agent.
5. Supervise the agent while it runs.
6. Capture success, failure, timeout, or cancellation.
7. Return or expose the final result.

This layer should become the foundation for future local LLM agents, coding agents, home automation agents, and remote messaging integrations.

---

## Current State

The project currently has:

- `Zaik.Application` root supervisor
- `Zaik.Agent.Supervisor` static supervisor
- `Zaik.Agent.HelloWorld` static example agent
- `Zaik.Agent.Base` reusable agent behaviour
- `Zaik.Clock` tick broadcaster

The project does **not** yet have:

- dynamic agent supervision
- task submission API
- task lifecycle tracking
- priority queue
- dispatcher
- agent registry
- task result storage
- timeout/retry/cancel handling

---

## Target Architecture

```text
Client / API / Messaging / CLI
        ↓
Zaik.submit_task/2
        ↓
Zaik.TaskStore
        ↓
Zaik.TaskQueue
        ↓
Zaik.Dispatcher
        ↓
Zaik.Agent.DynamicSupervisor
        ↓
Task-specific Agent Process
        ↓
Zaik.TaskStore result update
        ↓
Client receives or fetches result
```

Recommended supervision tree:

```text
Zaik.Application
├── Registry, name: Zaik.Agent.Registry
├── Registry, name: Zaik.Task.Registry
├── Zaik.TaskStore
├── Zaik.SessionStore
├── Zaik.MemoryStore
├── Zaik.TaskQueue
├── Zaik.Agent.DynamicSupervisor
├── Zaik.Dispatcher
├── Zaik.TaskWatchdog
└── Zaik.Clock
```

---

## Core Concepts

### Task

A task is a unit of work submitted to the harness.

Suggested struct:

```elixir
defmodule Zaik.Task do
  @type status ::
          :queued
          | :assigned
          | :running
          | :succeeded
          | :failed
          | :cancelled
          | :timed_out

  defstruct [
    :id,
    :type,
    :payload,
    :priority,
    :status,
    :session_id,
    :parent_entry_id,
    :context_entry_id,
    :agent_module,
    :agent_pid,
    :result,
    :error,
    :submitted_at,
    :started_at,
    :completed_at,
    timeout_ms: 60_000,
    max_retries: 0,
    attempts: 0,
    metadata: %{}
  ]
end
```

### Task Types

Initial examples:

```elixir
:echo
:llm_prompt
:home_automation
:code_task
```

Each task type should map to an agent module through a resolver.

Example:

```elixir
%{
  echo: Zaik.Agent.Echo,
  llm_prompt: Zaik.Agent.LLM,
  home_automation: Zaik.Agent.HomeAutomation
}
```

### Priority

Use numeric priority at first:

```elixir
0   # lowest
50  # normal
100 # high
```

Higher priority tasks should dispatch before lower priority tasks.

---

## Modules to Add

## 1. `Zaik.Task`

Defines the task struct and helper functions.

Responsibilities:

- create new tasks
- validate task fields
- expose status helpers
- centralize default timeout/retry values

Public API sketch:

```elixir
Zaik.Task.new(type, payload, opts \\ [])
Zaik.Task.mark_queued(task)
Zaik.Task.mark_running(task, agent_pid)
Zaik.Task.mark_succeeded(task, result)
Zaik.Task.mark_failed(task, reason)
```

---

## 2. `Zaik.TaskStore`

A GenServer that stores task state and results in memory.

Responsibilities:

- insert new tasks
- update lifecycle state
- fetch task by ID
- list tasks by status
- store result/error

Initial implementation can be in-memory using a map:

```elixir
%{
  task_id => %Zaik.Task{}
}
```

Public API sketch:

```elixir
Zaik.TaskStore.insert(task)
Zaik.TaskStore.get(task_id)
Zaik.TaskStore.update(task)
Zaik.TaskStore.update_status(task_id, status)
Zaik.TaskStore.complete(task_id, result)
Zaik.TaskStore.fail(task_id, reason)
Zaik.TaskStore.list(opts \\ [])
```

Future replacement options:

- ETS
- SQLite
- PostgreSQL
- event log

---

## Filesystem Session and Memory Layer

Zaik should use filesystem-backed session memory, similar in spirit to pi's session harness. Sessions should be append-only JSONL files rather than only in-memory maps. This provides durability, debuggability, replayability, branching, and a natural audit trail for tasks and agent interactions.

Pi stores sessions as JSONL with a header entry and a tree of entries linked by `id` and `parentId`. Zaik should adopt a similar model adapted for general task harness use.

### Storage location

Default global location:

```text
~/.zaik/sessions/<scope>/<timestamp>_<session_id>.jsonl
```

Recommended scope examples:

```text
~/.zaik/sessions/projects/<safe_project_path>/...
~/.zaik/sessions/chats/<provider>/<conversation_id>/...
~/.zaik/sessions/home/<home_id>/...
~/.zaik/sessions/system/...
```

Project-local optional location:

```text
.zaik/sessions/
```

Use project-local sessions only when explicitly configured/trusted. Default to the global location for safety and consistency.

### Session file format

Each session file should be JSONL. The first line is a session header:

```json
{"type":"session","version":1,"id":"session_uuid","timestamp":"2026-06-22T00:00:00Z","scope":"project","cwd":"/path/to/project"}
```

Subsequent lines are append-only entries. Entries should form a tree through `id` and `parentId`, enabling branching without creating separate files.

Common fields:

```elixir
%{
  type: "message" | "task" | "task_result" | "summary" | "artifact" | "custom",
  id: "8-char-or-uuid-entry-id",
  parentId: nil | "parent-entry-id",
  timestamp: DateTime.utc_now()
}
```

Recommended entry types:

| Entry type | Purpose | Included in LLM/task context? |
|---|---|---|
| `session` | file header/metadata | no |
| `message` | user/agent/system/tool message | yes |
| `task` | submitted task metadata | usually yes |
| `task_result` | task success/failure result | yes |
| `task_progress` | progress event | optional |
| `artifact` | file path/blob reference/output | optional |
| `summary` | compacted context summary | yes |
| `branch_summary` | summary when switching branches | yes |
| `custom` | extension/internal state | no by default |
| `label` | bookmark/checkpoint | no |

Example task-related entries:

```json
{"type":"message","id":"a1b2c3d4","parentId":null,"timestamp":"2026-06-22T00:00:01Z","role":"user","content":"Turn on the kitchen lights"}
{"type":"task","id":"b2c3d4e5","parentId":"a1b2c3d4","timestamp":"2026-06-22T00:00:02Z","taskId":"task_uuid","taskType":"home_automation","payload":{"command":"turn_on","target":"kitchen_lights"}}
{"type":"task_result","id":"c3d4e5f6","parentId":"b2c3d4e5","timestamp":"2026-06-22T00:00:04Z","taskId":"task_uuid","status":"succeeded","result":{"ok":true}}
```

### `Zaik.Session`

Represents a durable conversation/workflow/project/home context.

Suggested struct:

```elixir
defmodule Zaik.Session do
  defstruct [
    :id,
    :path,
    :scope,
    :cwd,
    :owner,
    :current_leaf_id,
    :created_at,
    :updated_at,
    metadata: %{}
  ]
end
```

### `Zaik.SessionStore`

Filesystem-backed session manager.

Responsibilities:

- create session JSONL files
- open existing sessions
- list sessions by scope/project/conversation
- append entries atomically
- track current leaf
- branch to an earlier entry
- load/replay entries from disk
- expose session metadata

Public API sketch:

```elixir
Zaik.SessionStore.create(opts \\ [])
Zaik.SessionStore.open(session_id_or_path)
Zaik.SessionStore.continue_recent(scope, opts \\ [])
Zaik.SessionStore.list(opts \\ [])
Zaik.SessionStore.append(session_id, entry)
Zaik.SessionStore.get_entry(session_id, entry_id)
Zaik.SessionStore.get_branch(session_id, leaf_id \\ :current)
Zaik.SessionStore.branch(session_id, entry_id)
```

Append operations should write one JSON object per line. Use a single writer process per open session, or route appends through `Zaik.SessionStore`, to avoid interleaved writes.

### `Zaik.MemoryStore`

A higher-level API over session entries. It should not hide the filesystem session model, but it should make common memory operations simple.

Responsibilities:

- append user/agent/system/tool messages
- append task submission events
- append task result events
- append summaries
- append artifact references
- fetch recent memory for a session
- fetch active branch memory

Public API sketch:

```elixir
Zaik.MemoryStore.append_message(session_id, role, content, opts \\ [])
Zaik.MemoryStore.append_task(session_id, task)
Zaik.MemoryStore.append_task_result(session_id, task, result)
Zaik.MemoryStore.append_summary(session_id, summary, opts \\ [])
Zaik.MemoryStore.recent(session_id, limit \\ 20)
Zaik.MemoryStore.branch(session_id, leaf_id \\ :current)
```

### `Zaik.ContextBuilder`

Builds task-specific context from filesystem-backed session memory.

Responsibilities:

- walk the active branch from current leaf to root
- select entries relevant to the task type
- include compacted summaries where available
- include recent messages/results/artifacts
- apply token or byte limits
- exclude entries marked `exclude_from_context`
- return context in a format usable by agents

Public API sketch:

```elixir
Zaik.ContextBuilder.build(task)
Zaik.ContextBuilder.build(session_id, opts \\ [])
```

For LLM tasks, the context can become a message list. For home automation tasks, it can include recent commands and home state observations. For coding tasks, it can include project metadata, recent tool results, and artifact references.

### Task/session integration

Tasks should optionally belong to a session:

```elixir
Zaik.submit_task(:llm_prompt, %{prompt: "hello"}, session_id: session_id)
```

Submission flow:

```text
submit_task(type, payload, session_id: ...)
  ↓
append user/request memory entry if appropriate
  ↓
create task with session_id and parent_entry_id
  ↓
append task entry to session JSONL
  ↓
enqueue task
  ↓
dispatcher starts agent
  ↓
agent/dispatcher builds context from ContextBuilder
  ↓
agent completes
  ↓
append task_result entry to session JSONL
  ↓
update TaskStore result
```

For sessionless tasks, the harness may create an ephemeral in-memory session or a durable system session depending on configuration.

### Compaction and summaries

Long sessions should support compaction. The full JSONL history remains on disk, while `summary` entries are used by `ContextBuilder` to fit active context into model/task limits.

Initial policy:

- keep all raw entries on disk
- include last N relevant entries directly
- include latest summary before the retained window
- manually trigger summary creation at first
- add automatic summary/compaction later

---

## 3. `Zaik.TaskQueue`

A GenServer-backed priority queue.

Responsibilities:

- enqueue task IDs
- dequeue highest priority task
- report queue length
- optionally support peeking and cancellation

The queue should store lightweight queue entries, not full task structs:

```elixir
%{
  task_id: task.id,
  priority: task.priority,
  enqueued_at: DateTime.utc_now()
}
```

Ordering:

1. Higher priority first.
2. Older task first for same priority.

Public API sketch:

```elixir
Zaik.TaskQueue.enqueue(task)
Zaik.TaskQueue.dequeue()
Zaik.TaskQueue.peek()
Zaik.TaskQueue.size()
Zaik.TaskQueue.remove(task_id)
```

Implementation note: a sorted list is acceptable for the first version. Replace later with a heap or ETS-backed queue if needed.

---

## 4. `Zaik.Agent.DynamicSupervisor`

A `DynamicSupervisor` responsible for starting task-specific agents.

Responsibilities:

- start an agent for a task
- isolate crashing agents
- support temporary or transient workers
- allow task-specific agent configuration

Public API sketch:

```elixir
Zaik.Agent.DynamicSupervisor.start_task_agent(task, agent_module)
Zaik.Agent.DynamicSupervisor.stop_agent(pid)
```

Recommended child spec:

```elixir
%{
  id: {agent_module, task.id},
  start: {agent_module, :start_link, [[task: task]]},
  restart: :temporary,
  type: :worker
}
```

Use `restart: :temporary` initially so completed or failed task agents are not automatically restarted unless the dispatcher explicitly retries the task.

---

## 5. `Zaik.Agent.Registry`

Use Elixir's built-in `Registry` for agent lookup.

Responsibilities:

- register task agents by task ID
- allow other processes to find a running agent
- support observability/debugging

Recommended supervision child:

```elixir
{Registry, keys: :unique, name: Zaik.Agent.Registry}
```

Suggested agent names:

```elixir
{:via, Registry, {Zaik.Agent.Registry, {:task_agent, task.id}}}
```

---

## 6. `Zaik.Dispatcher`

A GenServer that assigns queued tasks to agents.

Responsibilities:

- pull tasks from `Zaik.TaskQueue`
- resolve task type to agent module
- start task agent under `Zaik.Agent.DynamicSupervisor`
- monitor running agent
- handle completion/failure messages
- enforce concurrency limits
- enforce task timeouts
- trigger retries if configured

State sketch:

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

Public API sketch:

```elixir
Zaik.Dispatcher.dispatch_now()
Zaik.Dispatcher.state()
```

Internal flow:

```text
:dispatch
  ↓
if capacity available:
  dequeue task_id
  fetch task from TaskStore
  resolve agent module
  mark task assigned/running
  start agent
  monitor pid
  send agent start-work message
  schedule timeout
```

Completion flow:

```text
agent sends {:task_complete, task_id, result}
  ↓
Dispatcher marks task succeeded
  ↓
Dispatcher stops/cleans up agent
  ↓
Dispatcher attempts next dispatch
```

Failure flow:

```text
agent crashes or sends {:task_failed, task_id, reason}
  ↓
Dispatcher checks retry policy
  ↓
retry: increment attempts and requeue
  ↓
no retry: mark failed
```

Timeout flow:

```text
{:task_timeout, task_id}
  ↓
Dispatcher stops agent
  ↓
retry or mark timed_out
```

### OTP-first health tracking

The dispatcher should use Elixir/OTP primitives as the primary mechanism for live task tracking. A polling watchdog should not be the normal path for detecting agent death or ordinary task timeouts.

Primary mechanisms:

- agent death detection: `Process.monitor/1`
- task timeout detection: `Process.send_after/3`
- crash isolation: `DynamicSupervisor`
- agent lookup: `Registry`
- task completion/failure: explicit messages from agent to dispatcher
- retry policy: dispatcher-owned business logic

When the dispatcher starts an agent, it should monitor it:

```elixir
ref = Process.monitor(pid)
```

Then handle process exits through:

```elixir
{:DOWN, ref, :process, pid, reason}
```

When a task starts running, the dispatcher should schedule a timeout:

```elixir
timeout_ref = Process.send_after(self(), {:task_timeout, task_id}, timeout_ms)
```

When the task reaches a terminal state, the dispatcher should cancel the timeout:

```elixir
Process.cancel_timer(timeout_ref)
```

Task agents should generally be supervised with `restart: :temporary`. The supervisor isolates crashes, but it should not blindly restart failed task agents. Retrying a failed business task is a dispatcher/task-store decision, not a supervisor decision.

---

## 7. `Zaik.TaskWatchdog`

A lightweight reconciliation process that periodically scans task state for stale, inconsistent, or orphaned work.

The watchdog is a backup/reconciliation layer, not the primary execution mechanism. Normal task health should be tracked by dispatcher monitors, timeout refs, and supervisor semantics.

Responsibilities:

- periodically scan non-terminal tasks in `Zaik.TaskStore`
- detect stale `:queued`, `:assigned`, and `:running` tasks
- compare task store state against queue, dispatcher state, and agent registry
- repair recoverable inconsistencies
- requeue recoverable tasks when safe
- mark unrecoverable tasks as failed or timed out
- emit logs/telemetry for stale task events

Public API sketch:

```elixir
Zaik.TaskWatchdog.scan_now()
Zaik.TaskWatchdog.state()
```

Example state:

```elixir
%{
  scan_interval_ms: 30_000,
  assigned_stale_after_ms: 10_000,
  running_grace_ms: 5_000,
  queued_warning_after_ms: 300_000
}
```

Reconciliation examples:

| Condition | Suggested action |
|---|---|
| task is `:queued` in store but missing from queue | re-enqueue task |
| task is `:assigned` too long with no agent pid | requeue or fail |
| task is `:running` with nil pid | requeue or fail |
| task is `:running` with dead pid | requeue or fail |
| task is `:running` past timeout and dispatcher lost timer | stop agent if present, then retry or mark timed out |
| task is terminal but still in queue | remove from queue |
| task is terminal but agent is still registered | stop agent or log warning |

The watchdog should be conservative. It should avoid overwriting terminal states and should use the same transition helpers as the dispatcher so task lifecycle rules remain centralized.

---

## 8. `Zaik.Agent.TaskRunner`

Define a task-oriented agent behaviour separate from the current conversational `Zaik.Agent.Base`.

A task runner is an agent that performs one submitted task and reports completion.

Behaviour sketch:

```elixir
defmodule Zaik.Agent.TaskRunner do
  @callback run_task(task :: Zaik.Task.t(), state :: term()) ::
              {:ok, result :: term(), new_state :: term()}
              | {:error, reason :: term(), new_state :: term()}
end
```

Macro-provided GenServer flow:

```elixir
use Zaik.Agent.TaskRunner

@impl true
def run_task(task, state) do
  {:ok, task.payload, state}
end
```

The generated process should:

1. Initialize with `task` and `dispatcher`.
2. Receive a `:run_task` cast/message.
3. Call `run_task/2`.
4. Send result back to dispatcher.

---

## 9. `Zaik.Agent.Echo`

Create a simple first task agent for testing the harness.

Example behavior:

```elixir
Zaik.submit_task(:echo, %{message: "hello"})
# => {:ok, task_id}

Zaik.await_task(task_id)
# => {:ok, %{message: "hello"}}
```

This should be the first end-to-end validation agent before LLM or home automation work.

---

## 10. Public API in `Zaik`

Add harness-facing functions to `Zaik`.

Suggested API:

```elixir
Zaik.create_session(opts \\ [])
Zaik.continue_session(scope, opts \\ [])
Zaik.list_sessions(opts \\ [])
Zaik.submit_task(type, payload, opts \\ [])
Zaik.get_task(task_id)
Zaik.await_task(task_id, timeout \\ 60_000)
Zaik.cancel_task(task_id)
Zaik.list_tasks(opts \\ [])
Zaik.queue_size()
Zaik.get_session_context(session_id, opts \\ [])
```

Initial example:

```elixir
{:ok, task_id} = Zaik.submit_task(:echo, %{message: "hello"}, priority: 50)
{:ok, result} = Zaik.await_task(task_id)
```

---

## Task Lifecycle

```text
submitted
  ↓
queued
  ↓
assigned
  ↓
running
  ↓
 ┌───────────┬────────┬───────────┬────────────┐
 │ succeeded │ failed │ timed_out │ cancelled  │
 └───────────┴────────┴───────────┴────────────┘
```

State transition rules:

| From | To | Trigger |
|---|---|---|
| submitted | queued | task accepted |
| queued | assigned | dispatcher picks task |
| assigned | running | agent started successfully |
| running | succeeded | agent returns result |
| running | failed | agent returns error or crashes |
| running | timed_out | timeout fires |
| queued/running | cancelled | caller cancellation |
| failed/timed_out | queued | retry allowed |

---

## Dispatch Policy

Initial dispatch policy:

- FIFO within priority.
- Higher priority before lower priority.
- Fixed global concurrency limit.
- One task per agent process.
- Agent process exits after task completion.

Later extensions:

- per-agent-type concurrency limits
- long-lived reusable agents
- task affinity
- resource-aware scheduling
- GPU/CPU constraints
- dependency DAGs

---

## Error Handling

The dispatcher should handle:

- unknown task type
- failed agent start
- agent crash
- task timeout
- task cancellation
- malformed task payload
- retry exhaustion

Recommended result shapes:

```elixir
{:ok, result}
{:error, :unknown_task_type}
{:error, :timeout}
{:error, {:agent_crashed, reason}}
{:error, {:validation_failed, reason}}
```

---

## Testing Plan

The test suite should validate not only the happy path, but also concurrency, race conditions, idempotency, supervision behavior, and public API semantics. This harness will become the foundation for coding agents, LLM agents, home automation agents, and remote control surfaces, so failure behavior should be explicit and well tested.

---

### Unit Tests

Add tests for:

- `Zaik.Task.new/3`
- task ID generation
- task default values
- task status transitions
- task timestamp population
- task attempt incrementing
- task timeout/retry defaults
- task validation helpers
- priority queue ordering
- same-priority FIFO behavior
- queue removal by task ID
- queue size reporting
- task store insert/update/fetch
- task store list/filter behavior
- task type resolution
- unknown task type handling

---

### Integration Tests

Add tests for:

- submitting an echo task
- task is inserted into `Zaik.TaskStore`
- task is enqueued in `Zaik.TaskQueue`
- dispatcher starts an agent
- agent is registered in `Zaik.Agent.Registry`
- agent completes and stores result
- `await_task/2` returns final result
- failed task is marked failed
- timed-out task is marked timed out
- retryable task is requeued
- retry exhaustion marks final failure
- cancelled queued task is removed from queue
- cancelled running task stops the agent
- unknown task type fails cleanly
- agent start failure marks task failed

---

### Public API Tests

Add tests for the public `Zaik` API:

- `Zaik.submit_task/3` returns `{:ok, task_id}` for valid input
- `Zaik.submit_task/3` rejects invalid task types
- `Zaik.submit_task/3` rejects invalid priorities
- `Zaik.submit_task/3` rejects invalid timeouts
- `Zaik.submit_task/3` rejects invalid retry counts
- `Zaik.get_task/1` returns task for known ID
- `Zaik.get_task/1` returns a clear error for unknown ID
- `Zaik.list_tasks/1` filters by status
- `Zaik.list_tasks/1` filters by type
- `Zaik.queue_size/0` returns accurate queue size
- `Zaik.cancel_task/1` cancels queued tasks
- `Zaik.cancel_task/1` cancels running tasks
- `Zaik.cancel_task/1` rejects already completed tasks

---

### Await and Result Delivery Tests

`await_task/2` semantics should be explicit.

Add tests for:

- awaiting an already completed task returns immediately
- awaiting a running task blocks until completion
- awaiting a missing task returns a clear error
- awaiting a failed task returns the failure shape
- awaiting a cancelled task returns the cancellation shape
- awaiting a timed-out task returns the timeout shape
- caller await timeout does not change task status
- multiple callers can await the same task
- multiple callers receive the same final result
- result remains fetchable after `await_task/2` returns

Recommended result shapes:

```elixir
{:ok, result}
{:error, :not_found}
{:error, :cancelled}
{:error, :timeout}
{:error, {:task_failed, reason}}
```

---

### Concurrency Tests

The dispatcher should be tested under load and with bounded capacity.

Add tests for:

- dispatcher never exceeds `max_concurrency`
- queued tasks remain queued while capacity is full
- queued tasks dispatch as running tasks complete
- many tasks submitted concurrently all complete correctly
- high-priority tasks dispatch before low-priority tasks when capacity opens
- same-priority tasks maintain FIFO ordering under concurrent submission
- separate agent processes are started for separate tasks
- dispatcher state is cleaned up after each task finishes

Example scenario:

```text
Configure max_concurrency = 3.
Submit 10 blocking tasks.
Assert only 3 are running.
Release one task.
Assert exactly one queued task starts.
Release all tasks.
Assert all 10 eventually complete.
```

---

### Race Condition Tests

OTP systems often fail around edge timing cases. Add targeted tests for:

- task completes at the same time its timeout fires
- task is cancelled while being dispatched
- task is cancelled while completing
- agent crashes immediately after startup
- agent crashes after sending completion
- dispatcher receives duplicate completion messages
- dispatcher receives duplicate failure messages
- dispatcher receives a late completion after timeout
- task is removed from queue while dispatcher tries to dequeue it
- task store update races are resolved deterministically

Expected policy: terminal task states should be stable. Once a task is `:succeeded`, `:failed`, `:timed_out`, or `:cancelled`, later duplicate or stale messages should not corrupt the final state.

---

### Idempotency Tests

The task lifecycle should tolerate duplicate messages and repeated API calls.

Add tests for:

- completing an already completed task is ignored or rejected consistently
- failing an already succeeded task does not overwrite success
- succeeding an already failed task does not overwrite failure
- timing out an already completed task does not overwrite completion
- cancelling an already completed task returns a clear error
- cancelling an already cancelled task is safe
- retrying a task does not create duplicate queue entries
- submitting distinct tasks with identical payloads creates distinct IDs
- dispatcher cleanup can run more than once safely

---

### Supervision and Recovery Tests

Add tests for:

- crashing task agent does not crash system
- dispatcher observes `:DOWN`
- dynamic supervisor remains alive after child crash
- task failure is recorded after child crash
- dispatcher process can restart under its supervisor
- task queue behavior after dispatcher restart is explicit
- task store behavior after dispatcher restart is explicit
- running task agents are handled or reconciled after dispatcher restart
- application supervisor starts all harness components
- individual component restart strategy matches expectations

For the initial in-memory implementation, it is acceptable for some state to be lost on component restart, but the behavior should be documented and tested. Later persistent storage can improve recovery semantics.

---

### Watchdog/Reconciliation Tests

Add tests for `Zaik.TaskWatchdog`:

- watchdog scans only non-terminal tasks
- queued task missing from queue is re-enqueued
- terminal task still present in queue is removed
- assigned task stale beyond threshold is requeued or failed according to policy
- running task with nil pid is requeued or failed according to policy
- running task with dead pid is requeued or failed according to policy
- running task past timeout is marked timed out when dispatcher timer was lost
- terminal task is never overwritten by watchdog reconciliation
- watchdog uses central task transition helpers
- `scan_now/0` performs a deterministic scan in tests
- scheduled periodic scan does not overlap with a previous scan

The watchdog should be tested as a reconciliation safety net. Tests should still verify that normal crash detection uses `Process.monitor/1` and normal timeout detection uses dispatcher timer refs.

---

### Timeout and Retry Tests

Add tests for:

- task timeout is driven by dispatcher `Process.send_after/3`
- task timeout stops the running agent
- timed-out task is marked `:timed_out` when no retries remain
- timed-out task is requeued when retries remain
- failed task is requeued when retries remain
- `attempts` increments on each run
- retry exhaustion produces final failure
- retry preserves original task ID
- retry does not duplicate queue entries
- timeout timer is cancelled after success
- timeout timer is cancelled after failure
- timeout timer is cancelled after cancellation
- stale timeout messages after terminal state do not alter the task

---

### Validation and Error Shape Tests

Add tests for malformed submissions and internal failures:

- invalid task type
- unknown task type
- invalid payload shape
- invalid priority
- invalid timeout
- invalid retry count
- invalid metadata
- resolver returns invalid agent module
- agent module does not implement required behavior
- agent start callback returns error
- task runner returns invalid result shape

All errors should use consistent tuples, for example:

```elixir
{:error, :unknown_task_type}
{:error, {:validation_failed, reason}}
{:error, {:agent_start_failed, reason}}
{:error, {:invalid_agent_result, result}}
```

---

### Filesystem Session and Memory Tests

Add tests for filesystem-backed sessions:

- session file is created with a valid header
- session files are placed in the configured global directory
- project-local session storage is opt-in/configured
- entries append as valid JSONL
- append operations preserve entry order
- concurrent appends through `Zaik.SessionStore` do not interleave/corrupt lines
- session can be reopened from disk
- session entries replay into the expected tree
- current leaf is tracked correctly
- branch traversal returns root-to-leaf entries
- branching to an earlier entry preserves all history
- task submission appends a `task` entry
- task completion appends a `task_result` entry
- sessionless task policy is explicit and tested
- malformed session files return clear errors
- partial/corrupt trailing line handling is explicit
- deleting/removing session files is handled gracefully

Add tests for context building:

- context builder walks only the active branch
- context builder includes summaries correctly
- context builder keeps recent entries after a summary
- context builder excludes entries marked `exclude_from_context`
- context builder respects byte/token/count limits
- context builder includes task results relevant to the session
- context builder returns deterministic ordering
- context builder handles empty sessions
- context builder handles missing sessions clearly

---

### Observability Tests

Add tests for operational visibility:

- task timestamps are populated correctly
- task `submitted_at`, `started_at`, and `completed_at` ordering is valid
- `Zaik.TaskStore.list/1` filters correctly
- dispatcher state reports running tasks
- queue size is accurate after enqueue/dequeue/cancel
- task attempts are visible
- task agent PID is stored while running
- task agent PID is cleared or preserved according to chosen policy after completion

---

### Suggested Test Helpers

Create small test-only agents to make edge cases deterministic:

- `Zaik.TestAgent.Echo` - immediately succeeds
- `Zaik.TestAgent.Fail` - immediately fails
- `Zaik.TestAgent.Crash` - raises/exits during execution
- `Zaik.TestAgent.Blocking` - waits for a message before completing
- `Zaik.TestAgent.Slow` - sleeps past timeout
- `Zaik.TestAgent.InvalidResult` - returns malformed callback result

These agents make it easier to test concurrency, timeout, cancellation, and race conditions without relying on sleeps wherever possible.

---

## Implementation Phases

## Phase 1: Task Data and Storage

Deliverables:

- `Zaik.Task`
- `Zaik.TaskStore`
- basic task lifecycle helpers
- unit tests

Acceptance criteria:

- tasks can be created with unique IDs
- tasks can be inserted, fetched, and updated
- statuses and timestamps are tracked

---

## Phase 2: Filesystem Sessions and Memory

Deliverables:

- `Zaik.Session`
- `Zaik.SessionStore`
- `Zaik.MemoryStore`
- `Zaik.ContextBuilder`
- JSONL session file format
- session/task entry integration
- branch traversal
- basic context building

Acceptance criteria:

- sessions are persisted as JSONL files
- session files can be reopened and replayed
- task submission and completion append durable entries
- tasks can reference `session_id`, `parent_entry_id`, and `context_entry_id`
- context can be built from the active session branch
- full raw history remains on disk

---

## Phase 3: Priority Queue

Deliverables:

- `Zaik.TaskQueue`
- enqueue/dequeue/peek/size/remove APIs
- priority/FIFO tests

Acceptance criteria:

- high priority tasks dispatch first
- same priority tasks dispatch oldest first
- queue operations are deterministic

---

## Phase 4: Dynamic Agent Supervision and Registry

Deliverables:

- `Zaik.Agent.DynamicSupervisor`
- `Zaik.Agent.Registry`
- child specs for task agents
- simple manual start/stop test

Acceptance criteria:

- task agents can be started dynamically
- task agents are registered by task ID
- crashed task agents do not bring down the app

---

## Phase 5: Task Runner Behaviour and Echo Agent

Deliverables:

- `Zaik.Agent.TaskRunner`
- `Zaik.Agent.Echo`
- tests for direct task runner execution

Acceptance criteria:

- echo task agent accepts a task
- echo task agent reports success to caller/dispatcher
- errors are reported in a consistent shape

---

## Phase 6: Dispatcher

Deliverables:

- `Zaik.Dispatcher`
- task type resolver
- max concurrency
- agent process monitoring with `Process.monitor/1`
- per-task timeout refs with `Process.send_after/3`
- timeout cancellation on terminal states
- completion/failure handling

Acceptance criteria:

- dispatcher pulls from queue
- dispatcher starts appropriate agent
- task completion updates store
- failed/crashed agents update task failure through monitor `:DOWN` handling
- timed-out tasks are handled through dispatcher timer messages
- stale monitor or timeout messages do not corrupt terminal task state

---

## Phase 7: Task Watchdog

Deliverables:

- `Zaik.TaskWatchdog`
- periodic reconciliation scan
- manual `scan_now/0` test hook
- stale queued/assigned/running task detection
- conservative repair/requeue/fail policies

Acceptance criteria:

- watchdog can repair queued task/store inconsistencies
- watchdog can detect running tasks whose agent disappeared
- watchdog can recover tasks after dispatcher restart loses monitor/timeout refs
- watchdog does not overwrite terminal task states
- watchdog remains secondary to normal OTP monitor/timer flow

---

## Phase 8: Public API

Deliverables:

- `Zaik.create_session/1`
- `Zaik.continue_session/2`
- `Zaik.list_sessions/1`
- `Zaik.get_session_context/2`
- `Zaik.submit_task/3`
- `Zaik.get_task/1`
- `Zaik.await_task/2`
- `Zaik.cancel_task/1`
- `Zaik.list_tasks/1`
- `Zaik.queue_size/0`

Acceptance criteria:

- user can create/open/list filesystem-backed sessions
- user can submit and await an echo task from public API
- submitted tasks can be associated with a session
- task submission and completion are durable in the session JSONL file
- result is returned once complete
- failures return clear error tuples

---

## Phase 9: Cleanup and Documentation

Deliverables:

- update `README.md`
- add architecture notes
- document task lifecycle
- document example usage
- document next integration points for LLM and messaging

Acceptance criteria:

- new developer can understand and run the harness
- tests cover happy path and failure path
- future LLM/messaging work has a stable integration layer

---

## Initial End-to-End Example

Target usage after implementation:

```elixir
{:ok, task_id} =
  Zaik.submit_task(:echo, %{message: "hello Zaik"}, priority: 50)

{:ok, result} = Zaik.await_task(task_id, 5_000)

result
# => %{message: "hello Zaik"}
```

Inspect task state:

```elixir
{:ok, task} = Zaik.get_task(task_id)

task.status
# => :succeeded
```

---

## Future Extensions

After this core harness exists, later phases can add:

- `Zaik.Agent.LLM`
- `Zaik.LLM.Ollama`
- remote messaging command ingress
- home automation adapters
- persistent task storage
- streaming task outputs
- task progress events
- distributed node support
- Web UI or TUI
- permission model for remote commands

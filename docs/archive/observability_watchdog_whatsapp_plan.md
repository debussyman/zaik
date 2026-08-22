# Zaik Observability, Watchdog, and WhatsApp Control Plane Plan

## Goal

Move Zaik from a basic task dispatcher into an operable harness that can observe itself, reconcile stale state, and expose a remote chat interface so the user can ask the harness about its own health and task state.

Priorities:

1. Runtime observability over exhaustive dispatcher unit testing.
2. Watchdog/reconciliation over fragile assumptions about perfect task lifecycle events.
3. Minimal WhatsApp/SMS integration for conversational harness status and task submission.

---

## Current State

Zaik currently has:

- `Zaik.Task`
- `Zaik.TaskStore` - in-memory task state
- `Zaik.TaskQueue` - in-memory priority queue
- `Zaik.Dispatcher` - starts task agents dynamically
- `Zaik.Agent.DynamicSupervisor`
- `Zaik.Agent.TaskRunner`
- `Zaik.Agent.Echo`
- `Zaik.TaskResolver`
- `Zaik.SessionStore` - filesystem-backed JSONL sessions
- `Zaik.MemoryStore` - filesystem-backed session memory convenience layer
- `Zaik.ContextBuilder`

Current public APIs include:

```elixir
Zaik.submit_task/3
Zaik.await_task/2
Zaik.cancel_task/1
Zaik.get_task/1
Zaik.list_tasks/1
Zaik.queue_size/0
Zaik.create_session/1
Zaik.list_sessions/1
Zaik.get_session_context/2
```

Current limitation:

- Session memory is durable.
- Task store and task queue are still in-memory.
- There is no watchdog/reconciler.
- There is no structured runtime observability API.
- There is no remote chat/control interface.

---

## Guiding Philosophy

Elixir/OTP should handle process isolation and crash containment.

The harness should not try to prevent every possible process failure through brittle code or excessive tests. Instead, it should make system state visible and recoverable.

Recommended approach:

```text
OTP supervision handles process failure.
Dispatcher handles normal task lifecycle.
Observability exposes what is happening.
Watchdog reconciles stale/inconsistent state.
WhatsApp/SMS lets the user inspect and command the harness remotely.
```

---

# Phase 1: Observability Foundation

## Goal

Expose the state of the harness in a structured way so local APIs, the watchdog, and WhatsApp commands can all ask the same questions.

## Modules to Add

### `Zaik.Observability`

A facade module for system introspection.

File:

```text
lib/zaik/observability.ex
```

Responsibilities:

- summarize harness health
- report task counts by status
- report queue size
- report dispatcher running tasks
- report registered task agents
- report recent sessions
- report uptime/process info
- expose data in machine-readable maps

Suggested API:

```elixir
Zaik.Observability.snapshot()
Zaik.Observability.health()
Zaik.Observability.task_summary()
Zaik.Observability.dispatcher_summary()
Zaik.Observability.agent_summary()
Zaik.Observability.session_summary(opts \\ [])
```

Example snapshot:

```elixir
%{
  status: :ok,
  node: Node.self(),
  time: DateTime.utc_now(),
  queue: %{
    size: 3
  },
  tasks: %{
    queued: 3,
    running: 1,
    succeeded: 42,
    failed: 2,
    cancelled: 0,
    timed_out: 1
  },
  dispatcher: %{
    alive?: true,
    max_concurrency: 4,
    running_count: 1,
    running_task_ids: ["..."]
  },
  agents: %{
    registered_count: 1,
    task_agents: [%{task_id: "...", pid: "#PID<...>"}]
  }
}
```

## Public API additions

Add to `Zaik`:

```elixir
Zaik.snapshot()
Zaik.health()
Zaik.task_summary()
```

## Notes

This should be pure introspection. It should not mutate task state.

---

# Phase 2: Structured Events and Logging

## Goal

Make lifecycle events visible and append important events to session memory where relevant.

## Modules to Add

### `Zaik.Event`

Optional struct/helper for event shapes.

Suggested event fields:

```elixir
%{
  type: :task_submitted | :task_started | :task_succeeded | :task_failed | :task_timed_out | :task_cancelled,
  task_id: task.id,
  session_id: task.session_id,
  timestamp: DateTime.utc_now(),
  metadata: %{}
}
```

### `Zaik.EventLog`

Initially simple in-memory ring buffer, not a database.

Suggested API:

```elixir
Zaik.EventLog.append(event)
Zaik.EventLog.recent(limit \\ 50)
Zaik.EventLog.by_task(task_id)
Zaik.EventLog.by_session(session_id)
```

Supervise it under `Zaik.Application`.

## Dispatcher integration

The dispatcher should append events for:

- task started
- task succeeded
- task failed
- task timed out
- task cancelled
- agent crashed
- retry/requeue

## Session integration

For session-backed tasks, important lifecycle events should be written into the session JSONL file as entries.

Entry examples:

```json
{"type":"task_event","taskId":"...","event":"started"}
{"type":"task_event","taskId":"...","event":"failed","reason":"..."}
```

---

# Phase 3: Watchdog/Reconciliation

## Goal

Add a supervised process that periodically reconciles task, queue, dispatcher, and registry state.

This is not the primary lifecycle path. Normal task death and timeout should still be handled by OTP monitors and dispatcher timers. The watchdog is for stale, inconsistent, or orphaned state.

## Module to Add

### `Zaik.TaskWatchdog`

File:

```text
lib/zaik/task_watchdog.ex
```

Supervision tree:

```elixir
Zaik.TaskWatchdog
```

Start options:

```elixir
Zaik.TaskWatchdog.start_link(
  scan_interval_ms: 30_000,
  assigned_stale_after_ms: 10_000,
  running_stale_after_ms: 120_000,
  queued_warning_after_ms: 300_000
)
```

Suggested API:

```elixir
Zaik.TaskWatchdog.scan_now()
Zaik.TaskWatchdog.state()
```

## Reconciliation checks

### Queued tasks

Condition:

```text
TaskStore says task is :queued, but TaskQueue does not contain it.
```

Action:

```text
Re-enqueue task.
Emit event: :task_requeued_by_watchdog.
```

This requires adding `Zaik.TaskQueue.contains?/1` or exposing queue entries.

### Assigned tasks

Condition:

```text
Task stuck in :assigned too long.
```

Action:

```text
Requeue or fail based on attempts/max_retries.
```

### Running tasks with missing/dead pid

Condition:

```text
TaskStore says task is :running, but agent_pid is nil or dead.
```

Action:

```text
Requeue or fail based on attempts/max_retries.
```

### Running tasks not known by dispatcher

Condition:

```text
TaskStore says :running, but Dispatcher.state().running does not contain task_id.
```

Action:

```text
If agent pid is alive, either re-monitor through dispatcher later or stop/requeue.
Initial conservative policy: mark failed/requeue because dispatcher lost ownership.
```

### Terminal tasks still in queue

Condition:

```text
Task status is terminal but still queued.
```

Action:

```text
Remove from queue.
```

### Terminal tasks with live task agent

Condition:

```text
Task is terminal but task agent is still registered/alive.
```

Action:

```text
Terminate child under DynamicSupervisor.
```

## Queue changes needed

Add to `Zaik.TaskQueue`:

```elixir
Zaik.TaskQueue.contains?(task_id)
Zaik.TaskQueue.entries()
```

## Dispatcher changes needed

Possibly add:

```elixir
Zaik.Dispatcher.running_task_ids()
Zaik.Dispatcher.owns_task?(task_id)
```

or rely on `Zaik.Dispatcher.state()`.

---

# Phase 4: Internal Command Processor

## Goal

Before wiring WhatsApp/SMS, create a reusable text command layer.

This allows WhatsApp, CLI, future web UI, and future local chat agents to share the same command processing logic.

## Module to Add

### `Zaik.CommandProcessor`

File:

```text
lib/zaik/command_processor.ex
```

Suggested API:

```elixir
Zaik.CommandProcessor.process(text, context \\ %{})
```

Where `context` may include:

```elixir
%{
  user_id: "...",
  session_id: "...",
  channel: :whatsapp,
  sender: "+15551234567"
}
```

## Initial commands

Keep this small and safe.

```text
help
health
snapshot
queue
tasks
tasks running
tasks failed
task <task_id>
sessions
ask echo <message>
submit echo <message>
```

Example outputs:

```text
health
```

```text
Zaik is ok.
Queue: 0
Running: 0
Succeeded: 12
Failed: 1
Timed out: 0
```

```text
task abc123
```

```text
Task abc123
Status: succeeded
Type: echo
Submitted: ...
Completed: ...
Result: %{...}
```

## Safety

Do not add shell execution commands yet.
Do not add home automation mutation commands yet.
Do not add arbitrary code agent commands yet.

---

# Phase 5: WhatsApp/SMS Ingress

## Goal

Allow the user to text the harness and ask about its state.

The fastest practical path is Twilio SMS or Twilio WhatsApp because it has straightforward webhooks.

Recommended initial provider:

```text
Twilio SMS first, WhatsApp via Twilio next.
```

Reason:

- SMS webhook flow is simple.
- Twilio WhatsApp uses a very similar request/response flow.
- We can validate the command layer before handling WhatsApp-specific formatting.

## Dependencies

Add:

```elixir
{:plug, "~> 1.15"}
{:bandit, "~> 1.5"}
{:req, "~> 0.5"}
```

`Jason` already exists.

## Modules to Add

### `Zaik.Web.Router`

A small Plug router.

Routes:

```text
GET  /health
POST /webhooks/twilio/sms
POST /webhooks/twilio/whatsapp
```

### `Zaik.Web.Endpoint`

Supervised Bandit endpoint.

Config:

```elixir
config :zaik, Zaik.Web.Endpoint,
  port: 4040
```

### `Zaik.Messaging.TwilioWebhook`

Parses Twilio webhook params:

```text
From
To
Body
MessageSid
ProfileName
WaId
```

Validates sender allowlist.

Calls:

```elixir
Zaik.CommandProcessor.process(body, context)
```

Returns TwiML:

```xml
<Response><Message>...</Message></Response>
```

## Configuration

Add to `config/config.exs`:

```elixir
config :zaik, :messaging,
  enabled: false,
  allowed_senders: [],
  provider: :twilio
```

Environment-variable override examples:

```text
ZAIK_WEB_PORT=4040
ZAIK_ALLOWED_SENDERS=+15551234567,+15557654321
```

## Security

Minimum initial requirements:

- sender allowlist
- reject unknown senders
- log rejected attempts
- no arbitrary shell/code execution
- no destructive home automation commands

Later:

- Twilio signature verification
- per-command permissions
- confirmation prompts
- audit events

---

# Phase 6: Chat Session Mapping

## Goal

Messages from a phone number should map to a stable filesystem-backed Zaik session.

Session key examples:

```text
sms:+15551234567
whatsapp:+15551234567
```

Suggested helper:

```elixir
Zaik.Messaging.SessionMapper.get_or_create_session(channel, sender)
```

This should:

1. Look for an existing session for the sender/channel.
2. Continue it if found.
3. Create a new session if missing.
4. Append incoming user message to session memory.
5. Append outgoing harness response to session memory.

This gives every remote chat a durable JSONL audit trail.

---

# Recommended Implementation Order

## Slice 1: Observability facade

Deliverables:

- `Zaik.Observability`
- public `Zaik.snapshot/0`, `Zaik.health/0`, `Zaik.task_summary/0`
- no behavior changes

Acceptance:

```elixir
Zaik.snapshot()
# => useful map of queue/tasks/dispatcher/agents
```

## Slice 2: Command processor

Deliverables:

- `Zaik.CommandProcessor`
- commands: `help`, `health`, `snapshot`, `queue`, `tasks`, `task <id>`, `submit echo <text>`

Acceptance:

```elixir
Zaik.CommandProcessor.process("health")
Zaik.CommandProcessor.process("submit echo hello")
```

## Slice 3: Watchdog

Deliverables:

- `Zaik.TaskWatchdog`
- `Zaik.TaskQueue.contains?/1`
- `Zaik.TaskQueue.entries/0`
- event/log output for reconciliations

Acceptance:

```elixir
Zaik.TaskWatchdog.scan_now()
# repairs/reports stale state without crashing system
```

## Slice 4: Minimal web endpoint

Deliverables:

- Plug/Bandit endpoint
- `GET /health`
- basic supervised HTTP server

Acceptance:

```bash
curl localhost:4040/health
```

## Slice 5: Twilio SMS webhook

Deliverables:

- `POST /webhooks/twilio/sms`
- sender allowlist
- command processor integration
- TwiML response

Acceptance:

A Twilio SMS can ask:

```text
health
```

and receive harness status.

## Slice 6: Twilio WhatsApp webhook

Deliverables:

- `POST /webhooks/twilio/whatsapp`
- same command processor path
- WhatsApp sender normalization

Acceptance:

A WhatsApp message can ask:

```text
tasks
```

and receive task summary.

---

# What Not To Do Yet

Do not add:

- shell execution over WhatsApp
- code agent mutation commands
- home automation mutation commands
- arbitrary LLM tool execution
- open sender access
- full Phoenix app unless needed
- database persistence unless task durability becomes urgent

---

# Success Criteria

The next milestone is complete when you can text the harness:

```text
health
```

and get:

```text
Zaik is ok.
Queue: 0
Running: 0
Succeeded: N
Failed: M
Timed out: K
```

and text:

```text
submit echo hello
```

and get:

```text
Submitted echo task <task_id>.
Result: hello
```

while the harness records the conversation in a filesystem-backed session.

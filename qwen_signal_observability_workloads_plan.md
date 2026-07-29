# Qwen Implementation Plan: Signal Ingress, Observability, and First Real Workloads

## Compacted Context

Zaik is an Elixir/OTP-based personal agent harness intended to run home automation agents, coding agents, and local LLM agents. The project started with a basic supervision tree and a static hello-world agent. It now has a task harness foundation and dynamic dispatcher.

Current implemented pieces:

- `Zaik.Task` - task struct and lifecycle helpers
- `Zaik.TaskStore` - in-memory task state/result store
- `Zaik.TaskQueue` - in-memory priority queue
- `Zaik.Session` - session metadata
- `Zaik.SessionStore` - filesystem-backed JSONL session storage
- `Zaik.MemoryStore` - convenience API over `SessionStore`
- `Zaik.ContextBuilder` - builds context from active session branch
- `Zaik.Agent.DynamicSupervisor` - dynamically supervises task agents
- `Zaik.Agent.TaskRunner` - behavior/macro for one-shot task agents
- `Zaik.Agent.Echo` - first dynamic task agent
- `Zaik.TaskResolver` - maps task type to agent module
- `Zaik.Dispatcher` - dequeues tasks, starts agents, monitors them, handles completion/failure/timeout

Current public API includes:

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
Zaik.hello/0
Zaik.send_message/1
```

Current validation:

```text
28 tests, 0 failures
```

Important design decisions:

- Session memory is filesystem-backed JSONL.
- Task store and queue are still in-memory.
- OTP supervision should handle process crashes.
- The next priority is observability and remote interaction, not exhaustive unit tests.
- Remote ingress should use `signal-cli-rest-api`, not Twilio, not WhatsApp Business.
- The first remote interface should be safe: inspect status, submit echo tasks, inspect tasks/sessions. No shell execution yet.

Useful existing plan files:

```text
task_harness_implementation_plan.md
dynamic_dispatcher_implementation_spec.md
observability_watchdog_whatsapp_plan.md
```

Current working command:

```bash
nix develop -c mix test
```

---

# Objective

Implement a practical remote control path using Signal, then begin exercising the harness with real workloads.

The user wants to be able to message the harness over Signal and ask things like:

```text
health
tasks
queue
submit echo hello
task <task_id>
sessions
```

This should be implemented via `signal-cli-rest-api`, preferably with polling first because it is simpler and does not require a public HTTPS endpoint.

---

# Non-Goals For This Phase

Do not implement:

- WhatsApp Business API
- Twilio
- arbitrary shell execution over Signal
- destructive home automation commands
- full Phoenix app
- database persistence
- complex auth beyond sender allowlist
- LLM agent unless explicitly called out in the workload section

Keep this phase small, local, and operational.

---

# Phase 1: Observability Facade

## Goal

Expose structured harness state so Signal commands and future watchdog logic have a common introspection layer.

## Add Module

```text
lib/zaik/observability.ex
```

## API

```elixir
Zaik.Observability.snapshot()
Zaik.Observability.health()
Zaik.Observability.task_summary()
Zaik.Observability.queue_summary()
Zaik.Observability.dispatcher_summary()
Zaik.Observability.agent_summary()
Zaik.Observability.session_summary(opts \\ [])
```

## Add Public API in `lib/zaik.ex`

```elixir
Zaik.snapshot()
Zaik.health()
Zaik.task_summary()
```

## Snapshot Shape

Example:

```elixir
%{
  status: :ok,
  node: Node.self(),
  time: DateTime.utc_now(),
  queue: %{
    size: 0
  },
  tasks: %{
    queued: 0,
    assigned: 0,
    running: 0,
    succeeded: 3,
    failed: 1,
    cancelled: 0,
    timed_out: 0
  },
  dispatcher: %{
    alive?: true,
    max_concurrency: 4,
    running_count: 0,
    running_task_ids: []
  },
  agents: %{
    registered_count: 0,
    task_agents: []
  }
}
```

## Implementation Notes

Use existing APIs:

```elixir
Zaik.TaskStore.list()
Zaik.TaskQueue.size()
Zaik.Dispatcher.state()
Registry.select(Zaik.Agent.Registry, ...)
Zaik.SessionStore.list()
```

Do not mutate state in observability functions.

## Acceptance Criteria

In `iex -S mix` or tests:

```elixir
Zaik.snapshot()
Zaik.health()
Zaik.task_summary()
```

return useful maps without crashing.

---

# Phase 2: Command Processor

## Goal

Create a reusable text command interface. Signal ingress should call this. Future CLI, web, or LLM tools can also call this.

## Add Module

```text
lib/zaik/command_processor.ex
```

## API

```elixir
Zaik.CommandProcessor.process(text, context \\ %{})
```

`context` should support:

```elixir
%{
  channel: :signal,
  sender: "+15551234567",
  session_id: "..."
}
```

## Initial Commands

Implement these first:

```text
help
health
snapshot
queue
tasks
tasks queued
tasks running
tasks failed
task <task_id>
sessions
submit echo <message>
```

Optional alias:

```text
echo <message>
```

## Response Format

Return plain text strings suitable for Signal.

Examples:

### `health`

```text
Zaik is ok.
Queue: 0
Running: 0
Succeeded: 12
Failed: 1
Timed out: 0
```

### `tasks`

```text
Tasks
Queued: 0
Assigned: 0
Running: 1
Succeeded: 12
Failed: 1
Cancelled: 0
Timed out: 0
```

### `submit echo hello`

Should submit a task and await briefly.

Possible response:

```text
Submitted echo task <task_id>.
Result: hello
```

If await times out:

```text
Submitted echo task <task_id>.
Task is still running.
```

## Safety Rules

- Do not execute shell commands.
- Do not expose arbitrary Elixir evaluation.
- Do not mutate home automation state.
- Unknown commands should return help text.

## Acceptance Criteria

```elixir
Zaik.CommandProcessor.process("health")
Zaik.CommandProcessor.process("tasks")
Zaik.CommandProcessor.process("submit echo hello")
```

return readable strings.

---

# Phase 3: Signal Session Mapping

## Goal

Map a Signal sender to a durable filesystem-backed Zaik session so remote chat history is recorded.

## Add Module

```text
lib/zaik/messaging/session_mapper.ex
```

## API

```elixir
Zaik.Messaging.SessionMapper.get_or_create_session(channel, sender)
```

Example:

```elixir
{:ok, session} = Zaik.Messaging.SessionMapper.get_or_create_session(:signal, "+15551234567")
```

## Implementation Approach

Simple first version:

- Create a session with:

```elixir
scope: :signal,
cwd: "signal:+15551234567",
metadata: %{channel: :signal, sender: "+15551234567"}
```

- Look up existing sessions by `scope: :signal` and metadata if possible.
- If metadata filtering is awkward, use `cwd` convention and list sessions.
- If no matching session exists, create one.

## Session Memory

For each inbound Signal message:

```elixir
Zaik.MemoryStore.append_message(session.id, :user, body, metadata: %{sender: sender, channel: :signal})
```

For each outbound response:

```elixir
Zaik.MemoryStore.append_message(session.id, :agent, response, metadata: %{channel: :signal})
```

## Acceptance Criteria

Repeated messages from the same Signal sender append to the same session JSONL file.

---

# Phase 4: Signal Client

## Goal

Add a minimal client for `signal-cli-rest-api`.

## Assumed External Service

Use `signal-cli-rest-api`, commonly run with Docker.

Example local API base:

```text
http://localhost:8080
```

Expected config:

```elixir
config :zaik, :signal,
  enabled: false,
  api_url: "http://localhost:8080",
  account: "+15551234567",
  allowed_senders: [],
  poll_interval_ms: 5_000
```

Environment variable overrides are useful but optional:

```text
ZAIK_SIGNAL_ENABLED=true
ZAIK_SIGNAL_API_URL=http://localhost:8080
ZAIK_SIGNAL_ACCOUNT=+15551234567
ZAIK_SIGNAL_ALLOWED_SENDERS=+15557654321,+15559876543
```

## Add Dependency

If not already present, add:

```elixir
{:req, "~> 0.5"}
```

Run:

```bash
nix develop -c mix deps.get
```

## Add Module

```text
lib/zaik/messaging/signal_client.ex
```

## API

```elixir
Zaik.Messaging.SignalClient.receive(account \\ configured_account)
Zaik.Messaging.SignalClient.send_message(to, message, account \\ configured_account)
```

## signal-cli-rest-api Endpoints

Common endpoints depend on the REST API mode/version, but typical examples are:

```text
GET /v1/receive/{number}
POST /v2/send
```

Be prepared to adjust based on installed `signal-cli-rest-api` docs/version.

Typical send payload shape:

```json
{
  "message": "hello",
  "number": "+15551234567",
  "recipients": ["+15557654321"]
}
```

## Acceptance Criteria

From IEx, after external service is running:

```elixir
Zaik.Messaging.SignalClient.send_message("+15557654321", "hello from zaik")
```

sends a Signal message.

---

# Phase 5: Signal Poller

## Goal

Poll `signal-cli-rest-api` for inbound messages, route them through the command processor, and send responses.

## Add Module

```text
lib/zaik/messaging/signal_poller.ex
```

Supervise it only when enabled.

Options:

```elixir
Zaik.Messaging.SignalPoller.start_link(
  enabled: true,
  api_url: "http://localhost:8080",
  account: "+15551234567",
  allowed_senders: ["+15557654321"],
  poll_interval_ms: 5_000
)
```

## Responsibilities

- periodically call `SignalClient.receive/1`
- normalize incoming envelope/message shape
- ignore already processed messages
- enforce sender allowlist
- map sender to session
- append inbound message to session memory
- call `Zaik.CommandProcessor.process/2`
- send response back through `SignalClient.send_message/3`
- append outbound response to session memory

## State Shape

```elixir
%{
  account: "+15551234567",
  allowed_senders: MapSet.new([...]),
  poll_interval_ms: 5_000,
  seen: MapSet.new()
}
```

## Message Deduplication

Use one of these as the dedupe key, depending on what the API returns:

```elixir
message.id
message.timestamp
{sender, timestamp, body}
```

Keep the `seen` set bounded. For the first version, keeping the last 500 IDs is enough.

## Supervision Integration

In `Zaik.Application`, add the poller conditionally based on config.

Example:

```elixir
children = [
  ...,
  maybe_signal_poller()
]
|> Enum.reject(&is_nil/1)
```

## Acceptance Criteria

With `signal-cli-rest-api` running and config enabled:

Text Signal:

```text
health
```

Receive a response with Zaik health.

Text:

```text
submit echo hello
```

Receive echo task result.

---

# Phase 6: First Real Workloads

The user wants to start exercising the harness, not just developing infrastructure. After Signal health/status works, add at least one useful workload.

## Workload Option A: Local Command-Free System Inspection Agent

Safe and useful.

Task type:

```elixir
:system_status
```

Agent:

```text
Zaik.Agent.SystemStatus
```

Behavior:

- returns OS/process/runtime info without shell execution
- uses Erlang VM APIs where possible

Example payload:

```elixir
%{detail: :basic}
```

Example result:

```elixir
%{
  node: Node.self(),
  uptime_ms: ...,
  process_count: :erlang.system_info(:process_count),
  memory: :erlang.memory(),
  schedulers: :erlang.system_info(:schedulers_online)
}
```

Signal command:

```text
system
```

or:

```text
submit system
```

## Workload Option B: Local Ollama Prompt Agent

Useful if Ollama is installed.

Task type:

```elixir
:llm_prompt
```

Modules:

```text
Zaik.LLM.OllamaClient
Zaik.Agent.LLM
```

Config:

```elixir
config :zaik, :llm,
  provider: :ollama,
  ollama_url: "http://localhost:11434",
  default_model: "qwen3"
```

Signal command:

```text
ask <prompt>
```

Caution:

- Keep timeouts longer for LLM tasks.
- Do not add tool execution yet.
- Just prompt and return text.

## Recommended First Workload

Implement **SystemStatus** first because it has no external dependency and exercises the task harness.

Then implement **Ollama LLM prompt** once Signal command flow is stable.

---

# Phase 7: Watchdog/Reconciliation

Once Signal can query state, add watchdog so the harness can heal/report stale state.

## Add Module

```text
lib/zaik/task_watchdog.ex
```

## Add Queue APIs

```elixir
Zaik.TaskQueue.contains?/1
Zaik.TaskQueue.entries/0
```

## Watchdog API

```elixir
Zaik.TaskWatchdog.scan_now()
Zaik.TaskWatchdog.state()
```

## Reconciliation Checks

- queued task in store but missing from queue -> requeue
- terminal task in queue -> remove
- running task with missing/dead pid -> requeue or fail
- running task not owned by dispatcher -> requeue/fail
- terminal task with live registered agent -> terminate agent

## Signal Command

Add:

```text
watchdog
watchdog scan
```

Example response:

```text
Watchdog scan complete.
Requeued: 1
Removed terminal queued tasks: 0
Failed orphaned running tasks: 0
```

---

# Tests To Add

Keep tests practical and focused.

## Observability Tests

- `snapshot/0` returns queue/task/dispatcher keys
- task summary changes after an echo task succeeds

## Command Processor Tests

- `health`
- `tasks`
- `submit echo hello`
- unknown command returns help

## Session Mapper Tests

- same sender returns same session
- different sender returns different session

## Signal Client Tests

Use mocks or adapter injection if practical. Do not require live Signal service in automated tests.

## Signal Poller Tests

Unit-test message normalization and allowlist behavior without live network.

---

# Suggested Implementation Order For Qwen

1. Add `Zaik.Observability`
2. Add `Zaik.CommandProcessor`
3. Add `Zaik.Messaging.SessionMapper`
4. Add `Zaik.Messaging.SignalClient`
5. Add `Zaik.Messaging.SignalPoller`
6. Add config for Signal
7. Add SystemStatus task agent
8. Add Signal commands for `health`, `tasks`, `submit echo`, and `system`
9. Add watchdog only after the chat loop works

---

# Manual Setup Notes For signal-cli-rest-api

One common Docker setup:

```bash
docker run -d \
  --name signal-cli-rest-api \
  -p 8080:8080 \
  -v signal-cli-config:/home/.local/share/signal-cli \
  bbernhard/signal-cli-rest-api:latest
```

Registration/linking depends on the chosen mode and whether using a dedicated number. Consult the container docs for exact commands.

Do not expose this API publicly without firewall/auth.

---

# Done Criteria

This phase is done when:

1. Tests pass:

```bash
nix develop -c mix test
```

2. In IEx:

```elixir
Zaik.CommandProcessor.process("health")
Zaik.CommandProcessor.process("submit echo hello")
```

returns useful text.

3. With `signal-cli-rest-api` running, sending Signal message:

```text
health
```

returns harness health.

4. Sending:

```text
submit echo hello
```

submits a real task, dispatches it, and returns the result.

5. Sending:

```text
system
```

runs a real `:system_status` workload and returns useful runtime info.

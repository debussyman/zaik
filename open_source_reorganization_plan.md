# Open Source Reorganization Plan

Zaik has grown from a personal house-agent project into a reusable local-first Elixir/OTP agent harness. This plan tracks the work needed to make the repository attractive, understandable, and contributor-friendly as an open source project.

## Goals

- Present Zaik as a reusable local agent runtime, not only as one household bot.
- Separate core architecture from optional adapters and domain integrations.
- Make extension points obvious for contributors.
- Keep the project testable with `nix develop -c mix test`.
- Preserve the current working Telegram/home-agent setup while reorganizing gradually.

## Current Architecture Summary

Zaik currently includes several overlapping concerns under one top-level namespace:

- Core runtime:
  - `Zaik.Task`
  - `Zaik.TaskStore`
  - `Zaik.TaskQueue`
  - `Zaik.Dispatcher`
  - `Zaik.Agent.DynamicSupervisor`
  - `Zaik.Agent.TaskRunner`
  - `Zaik.TaskWatchdog`
  - `Zaik.Scheduler`
  - `Zaik.Clock`
  - `Zaik.Observability`
- Memory/session storage:
  - `Zaik.Session`
  - `Zaik.SessionStore`
  - `Zaik.MemoryStore`
  - `Zaik.ContextBuilder`
- Agent brain and tool loop:
  - `Zaik.AgentChat`
  - `Zaik.AgentChat.Prompts`
  - `Zaik.AgentChat.Evals`
  - `Zaik.AgentChat.SelfImprovementJob`
  - `Zaik.Analytics.SQLTool`
- Messaging adapters:
  - `Zaik.Messaging.TelegramClient`
  - `Zaik.Messaging.TelegramPoller`
  - `Zaik.Messaging.SignalClient`
  - `Zaik.Messaging.SignalPoller`
  - `Zaik.Messaging.SessionMapper`
- Home adapters/domain:
  - `Zaik.MQTT.Client`
  - `Zaik.Home.DeviceStore`
  - `Zaik.Home.HistoryStore`
  - `Zaik.Home.Trends`
  - `Zaik.Home.Zigbee2MQTT`
  - `Zaik.Home.Zigbee2MQTTBootstrapper`
- LLM adapter:
  - `Zaik.LLM.OllamaClient`
- User ingress:
  - `Zaik.ChatRouter`
  - `Zaik.CommandProcessor`

The core pieces are reusable, but the current layout makes the repository feel tightly coupled to one house, Telegram/Signal, Ollama, MQTT, Zigbee2MQTT, and Lily's room.

## Proposed Conceptual Layers

### 1. Runtime Core

Reusable OTP task harness and scheduling infrastructure.

Target namespace:

```text
lib/zaik/runtime/
  task.ex
  task_store.ex
  task_queue.ex
  dispatcher.ex
  dynamic_supervisor.ex
  task_runner.ex
  task_resolver.ex
  watchdog.ex
  scheduler.ex
  clock.ex
  observability.ex
```

Target modules:

```elixir
Zaik.Runtime.Task
Zaik.Runtime.TaskStore
Zaik.Runtime.TaskQueue
Zaik.Runtime.Dispatcher
Zaik.Runtime.DynamicSupervisor
Zaik.Runtime.TaskRunner
Zaik.Runtime.TaskResolver
Zaik.Runtime.TaskWatchdog
Zaik.Runtime.Scheduler
Zaik.Runtime.Clock
Zaik.Runtime.Observability
```

### 2. Memory and Persistence

Filesystem-backed session memory and operational telemetry.

Target namespace:

```text
lib/zaik/memory/
  session.ex
  session_store.ex
  store.ex
  context_builder.ex

lib/zaik/storage/
  telemetry_store.ex
```

Target modules:

```elixir
Zaik.Memory.Session
Zaik.Memory.SessionStore
Zaik.Memory.Store
Zaik.Memory.ContextBuilder
Zaik.Storage.TelemetryStore
```

### 3. Brain and Tool Loop

The normal conversational house-agent brain, prompt scaffolding, evals, and read-only tool use.

Target namespace:

```text
lib/zaik/brain/
  agent_chat.ex
  prompts.ex
  evals.ex
  self_improvement_job.ex
```

Target modules:

```elixir
Zaik.Brain.AgentChat
Zaik.Brain.Prompts
Zaik.Brain.Evals
Zaik.Brain.SelfImprovementJob
```

Related generic tool layer:

```text
lib/zaik/tools/
  sql_tool.ex
  registry.ex
```

Target modules:

```elixir
Zaik.Tools.SQLTool
Zaik.Tools.Registry
```

### 4. Ingress and Commands

Shared message ingress and explicit commands independent of Telegram/Signal/etc.

Target namespace:

```text
lib/zaik/ingress/
  message.ex
  chat_router.ex
  command_processor.ex

lib/zaik/commands/
  tasks.ex
  sessions.ex
  home.ex
  scheduler.ex
  proposals.ex
  diagnostics.ex
```

Target modules:

```elixir
Zaik.Ingress.Message
Zaik.Ingress.ChatRouter
Zaik.Ingress.CommandProcessor
Zaik.Commands.Tasks
Zaik.Commands.Sessions
Zaik.Commands.Home
Zaik.Commands.Scheduler
Zaik.Commands.Proposals
Zaik.Commands.Diagnostics
```

### 5. Optional Adapters

External systems should be framed as optional bridges.

Target namespace:

```text
lib/zaik/adapters/
  llm/ollama.ex
  messaging/telegram.ex
  messaging/signal.ex
  home/mqtt.ex
  home/zigbee2mqtt.ex
```

Target modules:

```elixir
Zaik.Adapters.LLM.Ollama
Zaik.Adapters.Messaging.Telegram
Zaik.Adapters.Messaging.Signal
Zaik.Adapters.Home.MQTT
Zaik.Adapters.Home.Zigbee2MQTT
```

### 6. Domains

House/home automation should be one domain built on the harness.

Target namespace:

```text
lib/zaik/domains/home/
  device_store.ex
  history_store.ex
  trends.ex
  sql_schema.ex
```

Target modules:

```elixir
Zaik.Domains.Home.DeviceStore
Zaik.Domains.Home.HistoryStore
Zaik.Domains.Home.Trends
Zaik.Domains.Home.SQLSchema
```

## Key Architectural Refactors

### Configurable Supervision Composition

Current `Zaik.Application` hardcodes core services, home services, MQTT, Signal, and Telegram in one supervision tree.

Goal: make the tree visibly composable:

```elixir
children =
  Zaik.Runtime.children(config) ++
  Zaik.Memory.children(config) ++
  Zaik.Storage.children(config) ++
  Zaik.Domains.Home.children(config) ++
  Zaik.Adapters.children(config)
```

Benefits:

- Core runtime can be understood without reading adapter code.
- Adapters become optional.
- Contributors can add integrations without editing unrelated runtime modules.

### Configurable Task Resolver

Current `Zaik.TaskResolver` uses a static map:

```elixir
%{
  echo: Zaik.Agent.Echo,
  system_status: Zaik.Agent.SystemStatus,
  llm_prompt: Zaik.Agent.LLM
}
```

Goal: allow task modules through config:

```elixir
config :zaik, :task_modules,
  echo: Zaik.Tasks.Echo,
  system_status: Zaik.Tasks.SystemStatus,
  llm_prompt: Zaik.Tasks.LLM
```

Benefits:

- Contributors can add task types without changing core.
- Examples can demonstrate custom task runners.

### Adapter Behaviours

Introduce behaviours for extension points:

```elixir
Zaik.Adapters.Messaging
Zaik.Adapters.LLM
Zaik.Tools.Tool
Zaik.Runtime.TaskRunner
Zaik.Domains.Home.Bridge
```

Benefits:

- Telegram, Signal, Ollama, MQTT, and Zigbee2MQTT become implementations.
- Tests can use fake adapters.
- Documentation can explain exactly how to extend Zaik.

### Decoupled MQTT Handling

Current `Zaik.MQTT.Client` directly calls:

```elixir
Zaik.Home.Zigbee2MQTT.handle_publish(topic, payload)
```

Goal: MQTT adapter should emit normalized events or call configured handlers.

Example direction:

```elixir
config :zaik, :mqtt,
  handlers: [Zaik.Adapters.Home.Zigbee2MQTT]
```

Benefits:

- MQTT can be reused for non-Zigbee2MQTT integrations.
- Home domain stays independent from transport.

### Unified Message Ingress Contract

Current Telegram/Signal pollers directly do session mapping, memory writes, chat routing, and reply sending.

Goal: define a common ingress message struct:

```elixir
%Zaik.Ingress.Message{
  channel: :telegram,
  sender_id: "...",
  chat_id: "...",
  chat_type: "group",
  text: "...",
  metadata: %{}
}
```

Then adapters call:

```elixir
Zaik.Ingress.handle_message(message)
```

Benefits:

- Telegram, Signal, CLI, Matrix, Discord, email, etc. can share routing/memory logic.
- Messaging adapters become small protocol translators.

### Split CommandProcessor

Current `Zaik.CommandProcessor` handles many domains in one module.

Goal: split into command groups:

```text
Zaik.Commands.Tasks
Zaik.Commands.Sessions
Zaik.Commands.Home
Zaik.Commands.Scheduler
Zaik.Commands.Proposals
Zaik.Commands.Diagnostics
```

Benefits:

- Easier contribution surface.
- Domain features can add commands without growing one giant module.

## Documentation and Repository Hygiene

### README Updates

Needed before opening the repo:

- Reposition Zaik as a local-first Elixir/OTP personal agent harness.
- Make Telegram, Signal, MQTT, Zigbee2MQTT, Ollama optional adapters.
- Remove stale claims that normal free-form chat uses a separate intent router.
- Clarify that raw `ask`/`submit llm` are diagnostics only.
- Update Signal wording now that Telegram is preferred.
- Add an architecture diagram or module-layer overview.
- Add a quick-start path that does not require the author's home setup.

### mix.exs Metadata

Current placeholders should be replaced:

```elixir
source_url: "https://github.com/yourusername/zaik"
maintainers: ["Your Name"]
```

Tasks:

- [ ] Set real `source_url`.
- [ ] Set maintainer name/handle.
- [ ] Confirm license.
- [ ] Add or verify `LICENSE` file.
- [ ] Decide whether package metadata should target Hex now or later.

### Planning Docs

Current root planning/spec files should move or be summarized:

```text
dynamic_dispatcher_implementation_spec.md
observability_watchdog_whatsapp_plan.md
project_plan.md
qwen_signal_observability_workloads_plan.md
task_harness_enhancement.md
task_harness_implementation_plan.md
technical_implementation.md
```

Recommended destination:

```text
docs/archive/
```

or convert into polished docs:

```text
docs/architecture.md
docs/task-runtime.md
docs/session-memory.md
docs/adapters.md
docs/home-automation.md
docs/agent-chat.md
docs/contributing.md
```

### Examples

Add small contributor-friendly examples:

```text
examples/minimal_runtime/
examples/custom_task/
examples/custom_messaging_adapter/
examples/telegram_house_bot/
examples/zigbee2mqtt_home/
examples/ollama_agent_chat/
```

### Secrets and Private Data

Before publishing:

- [ ] Confirm `.envrc` is untracked.
- [ ] Confirm `.direnv/` is untracked.
- [ ] Confirm private env files are not committed:
  - `~/.config/zaik/signal.env`
  - `~/.config/zaik/telegram.env`
- [ ] Scan tracked files for real phone numbers, Telegram IDs, bot tokens, API keys, local IPs, and personal names.
- [ ] Replace household-specific names like Lily in core docs/examples where generic examples would be better.
- [ ] Keep a separate personal/private deployment branch or local config for household-specific defaults.

## Suggested Target Tree

```text
lib/
  zaik.ex
  zaik/application.ex

  zaik/runtime/
    task.ex
    task_store.ex
    task_queue.ex
    dispatcher.ex
    dynamic_supervisor.ex
    task_runner.ex
    task_resolver.ex
    watchdog.ex
    scheduler.ex
    clock.ex
    observability.ex

  zaik/memory/
    session.ex
    session_store.ex
    store.ex
    context_builder.ex

  zaik/storage/
    telemetry_store.ex

  zaik/brain/
    agent_chat.ex
    prompts.ex
    evals.ex
    self_improvement_job.ex

  zaik/tools/
    sql_tool.ex
    registry.ex

  zaik/ingress/
    message.ex
    chat_router.ex
    command_processor.ex

  zaik/commands/
    tasks.ex
    sessions.ex
    home.ex
    scheduler.ex
    proposals.ex
    diagnostics.ex

  zaik/adapters/
    llm/ollama.ex
    messaging/telegram.ex
    messaging/signal.ex
    home/mqtt.ex
    home/zigbee2mqtt.ex

  zaik/domains/
    home/device_store.ex
    home/history_store.ex
    home/trends.ex
    home/sql_schema.ex
```

## Phased Execution Plan

### Phase 1: OSS Hygiene

- [ ] Update README to describe current one-brain architecture.
- [ ] Make Signal docs optional/deprecated relative to Telegram.
- [ ] Add `.env.example` files.
- [ ] Fix `mix.exs` metadata.
- [ ] Add/verify `LICENSE`.
- [ ] Move planning docs to `docs/archive/` or convert to polished docs.
- [ ] Add `CONTRIBUTING.md`.
- [ ] Add architecture docs.
- [ ] Run tracked-file secret/privacy scan.
- [ ] Ensure `nix develop -c mix test` passes.

### Phase 2: Clarify Boundaries Without Big Renames

- [ ] Add docs that classify modules into runtime, memory, brain, adapters, domains.
- [ ] Add behaviours for LLM client, messaging adapter, tool, and home bridge.
  - [x] LLM provider behaviour/facade added with Ollama and llama.cpp clients.
- [x] Mark legacy intent parser as deprecated; normal free-form chat uses `Zaik.AgentChat`.
- [ ] Make `TaskResolver` config-driven while preserving defaults.
- [ ] Make MQTT handler modules configurable.
- [ ] Introduce `Zaik.Ingress.Message` and shared ingress flow.
- [ ] Start slimming Telegram/Signal pollers into protocol adapters.
- [ ] Ensure all tests pass.

### Phase 3: Namespace Reorganization

- [ ] Move task runtime modules under `Zaik.Runtime.*`.
- [ ] Move memory/session modules under `Zaik.Memory.*`.
- [ ] Move telemetry under `Zaik.Storage.*`.
- [ ] Move agent-chat modules under `Zaik.Brain.*`.
- [ ] Move SQL tool under `Zaik.Tools.*`.
- [ ] Move Telegram/Signal/Ollama/MQTT/Zigbee modules under `Zaik.Adapters.*`.
- [ ] Move home domain stores/trends under `Zaik.Domains.Home.*`.
- [ ] Add temporary compatibility aliases if needed.
- [ ] Update tests and docs.
- [ ] Ensure all tests pass.

### Phase 4: Contributor Examples

- [ ] Add minimal runtime example.
- [ ] Add custom task runner example.
- [ ] Add custom messaging adapter example.
- [ ] Add Telegram bot example.
- [ ] Add Zigbee2MQTT home example.
- [ ] Add Ollama agent-chat example.

### Phase 5: Polish for Public Launch

- [ ] Add CI.
- [ ] Add issue templates.
- [ ] Add security policy or security notes.
- [ ] Add code of conduct if desired.
- [ ] Tag first public release.
- [ ] Publish announcement docs/examples.

## Architectural Principle to Preserve

Zaik should remain one coherent local personal agent harness:

```text
Core runtime is generic.
Memory is local-first and inspectable.
Adapters are optional.
Domains are pluggable.
The normal chat brain is externally unified.
Dangerous writes/control actions require confirmation.
```

## Notes

Do not split into an umbrella project yet. The codebase is still small enough that a single Mix app with clear namespaces is likely simpler and more contributor-friendly. Consider an umbrella only if adapters/domains become independently versioned packages later.

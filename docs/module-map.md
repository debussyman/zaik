# Module Map

This document classifies the current Zaik modules by architectural layer. It is a contributor guide for the transition from the original private-household layout to a reusable local-first agent harness.

Zaik is still a single Mix app. The current module names are intentionally being stabilized before larger namespace moves.

## Public API and application shell

| Current module/file | Role | Future direction |
| --- | --- | --- |
| `Zaik` | Public convenience API for sessions, tasks, health, home state, SQL, and chat. | Keep as the stable user-facing facade. |
| `Zaik.Application` | OTP supervision tree. | Split child construction into runtime/memory/storage/domain/adapter groups. |

## Runtime core

Reusable OTP task harness, scheduling, dispatch, watchdog, and health state.

| Current module/file | Role | Future target |
| --- | --- | --- |
| `Zaik.Task` | Task data model. | `Zaik.Runtime.Task` |
| `Zaik.TaskStore` | Filesystem-backed task persistence. | `Zaik.Runtime.TaskStore` |
| `Zaik.TaskQueue` | In-memory task queue GenServer. | `Zaik.Runtime.TaskQueue` |
| `Zaik.Dispatcher` | Pulls queued tasks and starts supervised runners. | `Zaik.Runtime.Dispatcher` |
| `Zaik.TaskResolver` | Maps task types to runner modules, merging built-in defaults with `config :zaik, :task_modules`. | `Zaik.Runtime.TaskResolver` after namespace migration. |
| `Zaik.Agent.DynamicSupervisor` | Dynamic supervisor for task runners. | `Zaik.Runtime.DynamicSupervisor` |
| `Zaik.Agent.TaskRunner` | Executes one task under supervision. | `Zaik.Runtime.TaskRunner` |
| `Zaik.TaskWatchdog` | Reconciles stuck/abandoned task state. | `Zaik.Runtime.TaskWatchdog` |
| `Zaik.Scheduler` | Lightweight scheduled jobs. | `Zaik.Runtime.Scheduler` |
| `Zaik.Clock` | Time abstraction for deterministic tests. | `Zaik.Runtime.Clock` |
| `Zaik.Observability` | Runtime health/snapshots. | `Zaik.Runtime.Observability` |

Task workload modules currently under `Zaik.Agent.*` are examples/default task implementations, not core runtime policy. Contributors can add or override task mappings with:

```elixir
config :zaik, :task_modules,
  custom_task: MyApp.CustomTask
```

Task workload modules implement/use `Zaik.Agent.TaskRunner`.

| Current module/file | Role | Future target |
| --- | --- | --- |
| `Zaik.Agent.Echo` | Echo task implementation. | `Zaik.Tasks.Echo` or example task. |
| `Zaik.Agent.SystemStatus` | System status task implementation. | `Zaik.Tasks.SystemStatus` or diagnostics command. |
| `Zaik.Agent.LLM` | Explicit diagnostic LLM task. | `Zaik.Tasks.LLM` or diagnostics command. |
| `Zaik.Agent.Base`, `Zaik.Agent.Supervisor`, `Zaik.Agent.HelloWorld` | Early/simple agent scaffolding. | Review for removal, examples, or compatibility. |

## Memory and persistence

Local-first memory and telemetry stores.

| Current module/file | Role | Future target |
| --- | --- | --- |
| `Zaik.Session` | Session data model. | `Zaik.Memory.Session` |
| `Zaik.SessionStore` | Filesystem session index/store. | `Zaik.Memory.SessionStore` |
| `Zaik.MemoryStore` | JSONL conversational memory. | `Zaik.Memory.Store` |
| `Zaik.ContextBuilder` | Builds prompt/runtime context from session memory. | `Zaik.Memory.ContextBuilder` |
| `Zaik.TelemetryStore` | SQLite operational telemetry and public views. | `Zaik.Storage.TelemetryStore` |

## Brain and tool loop

Normal free-form chat goes through one externally unified brain.

| Current module/file | Role | Future target |
| --- | --- | --- |
| `Zaik.AgentChat` | Bounded read-only tool loop for normal chat. | `Zaik.Brain.AgentChat` |
| `Zaik.AgentChat.Prompts` | Compact planner/final-answer prompts. | `Zaik.Brain.Prompts` |
| `Zaik.AgentChat.Evals` | Built-in regression/eval cases. | `Zaik.Brain.Evals` |
| `Zaik.AgentChat.SelfImprovementJob` | Periodic eval/notification job. | `Zaik.Brain.SelfImprovementJob` |
| `Zaik.Analytics.SQLTool` | Validated read-only SQL tool over documented views. | `Zaik.Tools.SQLTool` |
| `Zaik.Intent.Parser` | Deprecated legacy intent classifier. | Remove, quarantine, or move to legacy example. |

## Ingress and commands

Text routing and explicit deterministic commands.

| Current module/file | Role | Future target |
| --- | --- | --- |
| `Zaik.ChatRouter` | Routes explicit commands vs normal free-form chat. | `Zaik.Ingress.ChatRouter` |
| `Zaik.CommandProcessor` | Monolithic command handler. | Split into `Zaik.Commands.*` groups. |
| `Zaik.Messaging.SessionMapper` | Maps channel/chat keys to Zaik sessions. | Shared ingress/session utility. |

Next planned slice: introduce a common `Zaik.Ingress.Message` struct and shared ingress flow so protocol adapters do less application-level work.

## LLM provider layer

Provider-neutral LLM facade and implementations.

| Current module/file | Role | Future target |
| --- | --- | --- |
| `Zaik.LLM` | Provider-neutral call facade. | Keep facade, possibly move clients under adapters later. |
| `Zaik.LLM.Provider` | Provider behaviour. | Keep or alias from `Zaik.Adapters.LLM`. |
| `Zaik.LLM.OllamaClient` | Ollama provider. | `Zaik.Adapters.LLM.Ollama` |
| `Zaik.LLM.LlamaCppClient` | llama.cpp/`llama-server` provider. | `Zaik.Adapters.LLM.LlamaCpp` |
| `Zaik.LLM.HTTP` | Shared HTTP helper. | Keep internal to provider layer. |
| `Zaik.LLM.Telemetry` | LLM call telemetry helper. | Keep near provider/facade layer. |

## Messaging adapters

External chat protocols. These should become thin translators into common ingress.

| Current module/file | Role | Future target |
| --- | --- | --- |
| `Zaik.Messaging.TelegramClient` | Telegram Bot API client. | `Zaik.Adapters.Messaging.Telegram.Client` or similar. |
| `Zaik.Messaging.TelegramPoller` | Telegram polling, addressing, session/memory/routing/replies. | Split protocol polling from shared ingress handling. |
| `Zaik.Messaging.SignalClient` | Optional legacy Signal client. | `Zaik.Adapters.Messaging.Signal.Client` or legacy adapter. |
| `Zaik.Messaging.SignalPoller` | Optional legacy Signal polling/routing/replies. | Split protocol polling from shared ingress handling. |

## Home domain and home adapters

Home automation is one optional domain, not the whole harness.

| Current module/file | Role | Future target |
| --- | --- | --- |
| `Zaik.Home.DeviceStore` | In-memory current home device state. | `Zaik.Domains.Home.DeviceStore` |
| `Zaik.Home.HistoryStore` | SQLite home readings/history. | `Zaik.Domains.Home.HistoryStore` |
| `Zaik.Home.Trends` | Home sensor trend summaries. | `Zaik.Domains.Home.Trends` |
| `Zaik.Home.Zigbee2MQTT` | Zigbee2MQTT payload handling. | `Zaik.Adapters.Home.Zigbee2MQTT` or bridge into home domain. |
| `Zaik.Home.Zigbee2MQTTBootstrapper` | Loads Zigbee2MQTT retained/current state. | `Zaik.Adapters.Home.Zigbee2MQTTBootstrapper` |
| `Zaik.MQTT.Client` | MQTT subscription wrapper. | `Zaik.Adapters.Home.MQTT`; make handlers configurable first. |

## Compatibility rule during reorganization

Prefer incremental, reversible slices:

1. Add behaviours/configuration/docs first.
2. Make call sites use the new extension point.
3. Add compatibility aliases only when modules are renamed.
4. Run `nix develop -c mix test` after each slice.

This keeps the current home deployment restorable while making the open-source architecture clearer.

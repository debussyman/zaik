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
| `Zaik.AgentChat` | Bounded registered-tool loop for normal chat, with compatibility branches for SQL and blinds. | `Zaik.Brain.AgentChat` |
| `Zaik.AgentChat.Prompts` | Compact planner/final-answer prompts. | `Zaik.Brain.Prompts` |
| `Zaik.AgentChat.Evals` | Live-model regression/eval cases for SQL and fake home-control tool use. | `Zaik.Brain.Evals` |
| `Zaik.AgentChat.RoutingEvals` | Deterministic skill-aware routing/prompt/SQL-guard evals. | `Zaik.Brain.RoutingEvals` |
| `Zaik.AgentChat.SelfImprovementJob` | Periodic eval/notification job. | `Zaik.Brain.SelfImprovementJob` |
| `Zaik.Tool` | Behaviour for runtime-discovered read/action tools. | Keep as the generic tool contract. |
| `Zaik.Tools.Registry` | Uncached runtime lookup of configured tool modules and aliases. | Keep as the hot-load-friendly tool registry. |
| `Zaik.Tools.Executor` | Runs actions under task supervision and request-scoped idempotency. | Keep as the generic execution boundary. |
| `Zaik.Tools.SQLQuery` | Registry adapter for the existing SQL tool. | Replace compatibility SQL branching incrementally. |
| `Zaik.Analytics.SQLTool` | Validated read-only SQL tool over documented views. | `Zaik.Tools.SQLTool` |
| `Zaik.Intent.Parser` | Deprecated legacy intent classifier. | Remove, quarantine, or move to legacy example. |

## Ingress and commands

Text routing and explicit deterministic commands.

| Current module/file | Role | Future target |
| --- | --- | --- |
| `Zaik.Ingress.Message` | Normalized inbound message struct for protocol adapters. | Keep as shared ingress contract. |
| `Zaik.Ingress` | Shared session mapping, memory writes, chat routing, and agent reply memory writes. | Keep as shared ingress flow. |
| `Zaik.ChatRouter` | Routes explicit commands vs normal free-form chat. | `Zaik.Ingress.ChatRouter` or keep as facade after command split. |
| `Zaik.CommandProcessor` | Monolithic command handler. | Split into `Zaik.Commands.*` groups. |
| `Zaik.SkillStore` | Filesystem-backed model-readable skills used as prompt context, not deterministic routines. | `Zaik.Runtime.SkillStore` or domain-scoped skill stores. |
| `Zaik.Messaging.SessionMapper` | Maps channel/chat keys to Zaik sessions. | Shared ingress/session utility. |

Telegram and optional legacy Signal now translate updates into `Zaik.Ingress.Message` and call `Zaik.Ingress.handle_message/2`. The pollers still own protocol-specific polling, allowlists, addressing, and sending replies.

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
| `Zaik.Home.DeviceStore` | In-memory raw current device state with observed/received timestamps. | `Zaik.Domains.Home.DeviceStore` |
| `Zaik.Home.Entity` | Adapter-neutral identity and typed current-state struct. | Keep as the home-domain entity contract. |
| `Zaik.Home.World` | Projects adapter payloads into capability-filtered current state. | Keep as the ordinary home reasoning boundary. |
| `Zaik.Home.Capability` | Behaviour for typed state detection and target validation. | Keep as the semantic capability contract. |
| `Zaik.Home.Capabilities.Registry` | Uncached runtime capability discovery. | Keep as the hot-load-friendly capability registry. |
| `Zaik.Home.Executor` | Behaviour for adapter execution of validated capability targets. | Keep as the capability executor contract. |
| `Zaik.Home.Executors.Registry` | Uncached runtime executor discovery. | Keep as the hot-load-friendly executor registry. |
| `Zaik.Home.ActionLedger` | SQLite request-scoped action idempotency ledger, including later verified-result reconciliation. | Keep in the home execution/policy layer. |
| `Zaik.Home.ActionVerifier` | Correlates action IDs with later adapter reports and validates target convergence. | Keep in the home execution/policy layer. |
| `Zaik.Home.ActionRetryPolicy` | Determines retry eligibility from verification state, fresh device state, cooldown, and attempt budget. | Keep as deterministic policy outside the model. |
| `Zaik.Home.ActionPlan` | Preflights coordinated actions, shares a bounded verification wait, and reports partial completion. | Keep as the multi-action execution boundary. |
| `Zaik.Home.HistoryStore` | SQLite home readings/history. | `Zaik.Domains.Home.HistoryStore` |
| `Zaik.Home.Trends` | Home sensor trend summaries. | `Zaik.Domains.Home.Trends` |
| `Zaik.Home.DevicePresetStore` | SQLite store for generic named device targets/presets. | `Zaik.Domains.Home.DevicePresetStore` |
| `Zaik.Home.Tools.GetState` / `ListDevices` | Typed registered read tools over `Zaik.Home.World`. | Keep as primary current-state tools. |
| `Zaik.Home.Tools.ControlDevice` | Generic entity/capability/target control tool. | Replace device-class-specific model tools over time. |
| `Zaik.Home.Tools.ExecutePlan` | Registered preflighted multi-action control tool. | Keep as the coordinated-action tool. |
| `Zaik.Home.Tools.RetryAction` | Policy-gated retry by persistent action ID; reconstructs only unresolved original targets. | Keep as the explicit retry boundary. |
| `Zaik.Home.ControlTool` / `Zaik.Home.Tools.ControlBlind` | Compatibility blind-control surfaces for AgentChat. | Retire after skills/prompts use `control_device`. |
| `Zaik.Home.Blinds` | Deterministic read/control layer for known Zigbee2MQTT blinds/window coverings using generic device presets. | `Zaik.Domains.Home.Blinds` |
| `Zaik.Home.Zigbee2MQTT` | Zigbee2MQTT payload handling. | `Zaik.Adapters.Home.Zigbee2MQTT` or bridge into home domain. |
| `Zaik.Home.Zigbee2MQTTBootstrapper` | Loads Zigbee2MQTT retained/current state. | `Zaik.Adapters.Home.Zigbee2MQTTBootstrapper` |
| `Zaik.MQTT.Client` | MQTT subscription/publish wrapper that fans incoming messages out to configured `Zaik.MQTT.Handler` modules. | `Zaik.Adapters.Home.MQTT` after namespace migration. |
| `Zaik.MQTT.Handler` | Behaviour for MQTT publish handlers. | Keep as generic transport extension point or move under adapters/runtime. |

## Compatibility rule during reorganization

Prefer incremental, reversible slices:

1. Add behaviours/configuration/docs first.
2. Make call sites use the new extension point.
3. Add compatibility aliases only when modules are renamed.
4. Run `nix develop -c mix test` after each slice.

This keeps the current home deployment restorable while making the open-source architecture clearer.

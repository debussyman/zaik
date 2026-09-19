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
| `Zaik.Home.EventBus` | Monitored local fanout for accepted canonical observation events. | Keep as the home-domain event boundary. |
| `Zaik.Home.OccupancyTracker` | Area-scoped multi-sensor occupancy projection with confidence, explicit transitions, and virtual-time absence debounce. | Add persisted restart restoration and sensor-specific confidence calibration. |
| `Zaik.Home.OccupancyTransitionStore` | Bounded durable history of meaningful occupancy transitions and advisory cross-area entry sequences without person-identity claims. | Use as evidence for future advisory dynamics, never as canonical presence. |
| `Zaik.Home.DeviceStore` | In-memory raw current device state with observed/received timestamps, stale/duplicate report rejection, and accepted-event publication. | `Zaik.Domains.Home.DeviceStore` |
| `Zaik.Home.Entity` | Adapter-neutral identity and typed current-state struct. | Keep as the home-domain entity contract. |
| `Zaik.Home.World` | Projects adapter payloads into capability-filtered current state carrying a schema version and contract fingerprint. | Keep as the ordinary home reasoning boundary. |
| `Zaik.Home.WorldContract` | Versioned runtime-discovered canonical entity/capability and calibration schemas with stable state-free fingerprints. | Extend with desired-state, confidence, and richer provenance contracts under explicit schema versions. |
| `Zaik.Home.AdapterCalibrationStore` | Durable per-entity/per-capability/per-adapter physical semantics with evidence fingerprints, operator identity, and append-only revisions. | Add additional explicitly typed calibration kinds and independently test consumers before they affect normalization or execution. |
| `Zaik.Home.Capability` | Behaviour for typed state detection and target validation. | Keep as the semantic capability contract. |
| `Zaik.Home.Capabilities.Registry` / `Capabilities.Contract` | Uncached discovery, fingerprints, and executable baseline composability validation. | Keep as the hot-load-friendly capability acceptance boundary. |
| `Zaik.Home.GoalContract` | Validated versioned skill contract for semantic goals, required evidence, constraints, tools, risk, and missing-data policy. | Keep as the declarative goal boundary. |
| `Zaik.Home.GoalContextBuilder` | Deterministically gathers and freshness-validates room, history, environment, and preset evidence before planning. | Add planner evidence-reference validation. |
| `Zaik.Home.Priority` | Fixed household authority classes and non-model-selected ordering weights. | Keep as the arbitration authority boundary. |
| `Zaik.Home.GoalCandidate` | Validated inert desired-state proposal with evidence, priority class, calibrated confidence, expiry, and fingerprint. | Keep in the home policy/arbitration layer. |
| `Zaik.Home.Policy` / `Zaik.Home.Policies.Registry` | Hot-load-friendly policy contract and uncached descriptor/fingerprint registry. | Keep in the home policy layer. |
| `Zaik.Home.Policies.DaylightHarvesting` | Shadow-first generic candidate policy for occupied, dark, daytime, cool rooms. | Keep as a built-in policy example/default. |
| `Zaik.Home.Policies.BedtimePrivacy` | Privacy/sleep authority policy driven by typed mode leases; bedtime targets come from generic device presets. | Keep as the built-in mode-driven privacy policy. |
| `Zaik.Home.Policies.SolarHeatAvoidance` | Comfort-authority hot/bright-room policy using calibrated generic `solar heat` cover presets. | Keep as a built-in policy without household device branches. |
| `Zaik.Home.Arbitrator` | Pure priority/conflict selection producing chosen and suppressed desired targets. | Keep in the home policy layer. |
| `Zaik.Home.Reconciler` | Pure freshness-aware diff from selected desired state to inert unresolved actions. | Keep before the existing action-plan execution boundary. |
| `Zaik.Home.Autonomy.Engine` | Supervised shadow/advisory context-policy-arbitration-reconciliation pipeline; active execution is deliberately rejected. | Evolve into the event-driven home autonomy coordinator. |
| `Zaik.Home.Autonomy.DecisionStore` | Bounded SQLite ledger for context, candidates, arbitration, reconciliation, safety gates, append-only execution outcomes, and rated operator feedback. | Add staged-plan linkage and automated verified outcomes at the future execution boundary. |
| `Zaik.Home.Autonomy.ManualOverrideStore` | Durable expiring area/home override leases with ownership, reasons, capability scope, cancellation audit, and automatic leases after explicit actions. | Add richer source-action metadata and configurable room defaults. |
| `Zaik.Home.Autonomy.ModeStore` | Durable typed bedtime/privacy context leases with owner, reason, source, expiry, supersession, cancellation, and event publication. | Extend only through validated mode contracts. |
| `Zaik.Home.Autonomy.ScopeModeStore` | Audited durable whole-home, area, policy, and area-policy off/shadow/advisory rollout rules with deterministic precedence. | Keep canary/active rejected until separate promotion gates exist. |
| `Zaik.Home.Tools.ActivateMode` / `GetModes` / `CancelMode` | Registered semantic tools for bounded natural-language mode lifecycle without direct device commands. | Keep behind normal action idempotency and exact-ID cancellation. |
| `Zaik.Home.Autonomy.DesiredStateStore` | Bounded durable ledger of selected semantic target leases and supersession history. | Drive restart-safe reconciliation once execution rollout gates exist. |
| `Zaik.Home.Autonomy.ConflictLock` | Pure gate that suppresses equivalent pending actions and blocks contradictory targets using verifier-owned in-flight state. | Keep immediately before action-budget assessment and execution. |
| `Zaik.Home.Autonomy.ActionBudgetStore` | Durable sliding-window per-device, room, and global autonomous-action accounting and pre-execution assessment. | Keep as a fail-closed execution gate; record only accepted autonomous actions. |
| `Zaik.Home.Executor` | Behaviour for adapter execution of validated capability targets. | Keep as the capability executor contract. |
| `Zaik.Home.Executors.Registry` | Uncached runtime executor discovery. | Keep as the hot-load-friendly executor registry. |
| `Zaik.Home.ActionLedger` | SQLite request-scoped action idempotency ledger, including later verified-result reconciliation. | Keep in the home execution/policy layer. |
| `Zaik.Home.ActionVerifier` | Correlates action IDs with ordered adapter reports, validates target convergence, and rejects conflicting pending targets. | Keep in the home execution/policy layer. |
| `Zaik.Home.ActionRetryPolicy` | Determines retry eligibility from verification state, fresh device state, cooldown, and attempt budget. | Keep as deterministic policy outside the model. |
| `Zaik.Home.ActionPlan` | Preflights coordinated actions, shares a bounded verification wait, and reports partial completion. | Keep as the multi-action execution boundary. |
| `Zaik.Home.ActionPlan.Condition` | Validates and evaluates bounded comparisons over declared canonical capability-state fields with explicit freshness. | Keep as the only staged-condition predicate boundary. |
| `Zaik.Home.StagedPlan` | Inert full-plan preflight for typed stages, conditions, bounded waits, deadlines, and cancel-on-false behavior. | Add supervised execution without weakening preflight. |
| `Zaik.Home.StagedPlanStore` | Durable prepared/waiting/running/completed/cancelled/expired lifecycle with exact-ID immediate or cooperative cancellation audit, stage checkpoints, bounded run diagnostics, restart recovery, and terminal retention. | Keep production execution unavailable until promotion gates exist. |
| `Zaik.Home.StagedPlanCoordinator` | Supervised ledger-protected stage execution, separate condition/verification waits, convergence-gated advancement, policy-gated retries, cooperative cancellation, and durable mirror-only resume across staged-store, ledger, verifier, and scheduler restart. | Accumulate replay evidence before considering any production binding. |
| `Zaik.Home.StagedPlanScheduler` | Mirror-only virtual-time and dependency-filtered canonical-observation wakeups, automatic polling, reconstruction after restart, and durable attempt/timeout/task-exit diagnostics. | Add staged retry policy integration while retaining the production execution barrier. |
| `Zaik.Home.StagedPlanWatchdog` | Read-only code-owned thresholds for missed wakeups, stuck evaluations, and repeated failures over active plans and the bounded run journal. | Expand issue classes as staged execution semantics grow. |
| `Zaik.Home.StagedPlanAlerts` | Explicit operator delivery of typed watchdog issues with durable fingerprint cooldown and hashed destination audit. | Expand typed issue rendering as diagnostics grow. |
| `Zaik.Home.StagedPlanAlertMonitor` | Disabled-by-default periodic watchdog delivery in bounded supervised tasks with timeout and health counters. | Add durable telemetry-write failure diagnostics without granting execution authority. |
| `Zaik.Home.HistoryStore` | SQLite home readings/history plus persisted areas, aliases, and provenance. | `Zaik.Domains.Home.HistoryStore` |
| `Zaik.Home.Trends` | Home sensor trend summaries. | `Zaik.Domains.Home.Trends` |
| `Zaik.Home.Query` | Shared normalization for model-authored entity and area lookup phrases. | Keep in the home-domain query boundary. |
| `Zaik.Home.HistorySummary` | Deterministic bounded aggregates, trends, freshness, and provenance over typed history. | `Zaik.Domains.Home.HistorySummary` |
| `Zaik.Home.Environment` | Deterministic civil-time, season, and configured day/night context. | Evolve behind a location/environment adapter boundary. |
| `Zaik.Home.RoomContext` | Reproducible area-level current state, occupancy, environment, and history snapshot. | `Zaik.Domains.Home.RoomContext` |
| `Zaik.Home.DevicePresetStore` | SQLite store for generic named device targets/presets. | `Zaik.Domains.Home.DevicePresetStore` |
| `Zaik.Home.Tools.GetState` / `ListDevices` | Typed registered read tools over `Zaik.Home.World`. | Keep as primary current-state tools. |
| `Zaik.Home.Tools.GetHistory` | Bounded typed capability/time-window history. | Keep as primary ordinary history tool. |
| `Zaik.Home.Tools.GetAreaContext` | Typed room summary combining current entities, deterministic environment, and bounded historical aggregates. | Keep as the goal/policy context read boundary. |
| `Zaik.Home.Tools.ControlDevice` | Generic entity/capability/target control tool. | Replace device-class-specific model tools over time. |
| `Zaik.Home.Tools.ApplyDevicePreset` | Resolves a named preset and re-enters validated capability control. | Keep as the generic preset action boundary. |
| `Zaik.Home.Tools.CaptureDevicePreset` | Captures fresh canonical capability state without accepting adapter payloads. | Extend through optional capability capture callbacks. |
| `Zaik.Home.Tools.ExecutePlan` | Registered preflighted multi-action control tool. | Keep as the coordinated-action tool. |
| `Zaik.Home.Tools.RetryAction` | Policy-gated retry by persistent action ID; reconstructs only unresolved original targets. | Keep as the explicit retry boundary. |
| `Zaik.Home.Mirror` / `Mirror.Scenario` / `Mirror.Scenarios` | Isolated runtime plus fingerprinted and reusable virtual-home fixture definitions. | Keep as the evaluation-world boundary. |
| `Zaik.Home.Mirror.Store` / `Mirror.Executor` | Deterministic virtual action/report traces, scheduled reports, faults, state transitions, and adapter execution. | Keep isolated from physical adapters. |
| `Zaik.Home.Mirror.PhysicalOracle` | Independently declared raw-adapter endpoint semantics that detect physically inverted outcomes without production normalization or verification code. | Expand to additional capabilities only with independent fixtures and explicit provenance. |
| `Zaik.Home.Mirror.Fixtures` | Loads declared history and operational data through production store APIs into per-run temporary SQLite databases. | Keep fixture schemas aligned with production migrations. |
| `Zaik.Time` / `Zaik.Home.Mirror.Clock` | Injectable production/system time facade and manually advanced mirror timer queue. | Keep time-sensitive policy deterministic in evals. |
| `Zaik.Home.Mirror.Runner` / `Mirror.Assertions` / `Mirror.Evals` | Executes scenarios and evaluates semantic desired state, fingerprints, labels, and safety invariants; exposed by `mix zaik.mirror_eval`. | Keep as the candidate acceptance boundary. |
| `Zaik.Home.Mirror.Replay` | Privacy-filtered production trace and capability-change scenario construction. | Keep raw household identity outside durable eval artifacts. |
| `Zaik.Learning.FailureLabels` / `CandidateGate` | Stable failure taxonomy and repeated mirror gates before shadow/canary/promotion. | Keep promotion decisions deterministic and operator-approved. |
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

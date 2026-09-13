# Zaik Architecture

Zaik is being organized as a local-first Elixir/OTP personal agent harness. The repository currently remains a single Mix app, but code is moving toward clearer internal layers.

For a module-by-module classification of the current code and future target namespaces, see [`module-map.md`](module-map.md).

## Layers

### Runtime core

Reusable OTP task and scheduling infrastructure:

- task model/store/queue
- dynamic dispatcher
- temporary supervised task runners
- watchdog reconciliation
- scheduler
- health/observability snapshots

### Memory and storage

Local-first state and history:

- filesystem-backed JSONL sessions under `~/.zaik/sessions`
- operational SQLite telemetry for tasks, messages, LLM calls, proposals, and agent traces
- domain-specific SQLite stores such as home telemetry history

### Brain and tools

Normal free-form chat uses one house-agent brain:

```text
Chat adapter -> Zaik.Ingress.Message -> Zaik.Ingress -> Zaik.ChatRouter -> Zaik.AgentChat -> registered tools
```

`Zaik.AgentChat` can use bounded read tools and validated home actions. Tool and home-capability modules are discovered at runtime through registries that do not cache module code, preserving Elixir's hot-code-loading path; the planner receives the relevant descriptor directly from that registry and active skills are checked for allowed tools and risk ceilings at execution. Home actions run in supervised tasks and use a request-scoped SQLite idempotency ledger. Coordinated changes are represented as one `Zaik.Home.ActionPlan`; every action is preflighted before execution and later failures retain structured partial-completion results. `Zaik.Home.ActionVerifier` associates generated action IDs with post-publication Zigbee2MQTT reports, validates capability-specific target convergence, and reconciles later verified results into the action ledger. `Zaik.Home.ActionRetryPolicy` allows an explicit retry only after fresh state proves non-convergence, subject to settle time, cooldown, attempt budget, and capability allowlisting; retry targets are reconstructed from the ledger rather than model arguments. `Zaik.Home.Mirror` runs these same boundaries against isolated virtual entities, presets, state transitions, faults, and desired-state assertions, with `Zaik.Home.Mirror.Executor` replacing physical MQTT execution. Its manually advanced clock drives delayed reports, verifier expiration, timestamps, and retry timing without wall-clock sleeps. Scenario history and operational telemetry are loaded through production store APIs into per-run temporary SQLite databases, and internal SQL-tool bindings ensure mirror reads never reach production files. Scheduled mirror reports separate source-observed time from delivery time, enabling stale, duplicate, out-of-order, and conflicting-action regressions. Canonical state ignores stale/duplicate reports, while the verifier rejects conflicting pending targets before adapter execution. Persisted area IDs and aliases overlay adapter identity for lookup, and typed capability-history reads expose bounded source-observed values with provenance without asking the model to write SQL. Mirror and AgentChat trajectories include tool/capability/scenario fingerprints and structured failure labels. Candidate prompts, adapters, and models require repeated clean mirror gates before shadowing, with explicit operator evidence for canaries or promotion. Low-risk controls may execute directly; higher-risk capabilities remain intended for proposal/confirmation policy.

### Adapters

External systems should be optional adapters. Current examples include:

- LLM providers: Ollama and llama.cpp/`llama-server`
- messaging: Telegram and legacy Signal
- home automation: MQTT/Zigbee2MQTT

Adapters should translate external protocol details into Zaik's internal APIs without owning core runtime policy.

### Domains

Home automation is one domain built on the harness, not the whole harness. Future domains might include calendar, email, files, finance, or other local personal-agent capabilities.

### Home state and capability boundary

`Zaik.Home.World` projects raw adapter state into stable entities with typed capabilities. `Zaik.Home.Capabilities.Registry` owns semantic state and target validation, while `Zaik.Home.Executors.Registry` maps validated targets to adapter execution. `Zaik.Home.RoomContext` expands a matched entity to its persisted area and combines current entities with deterministic environment facts, active household modes and overrides, scoped presets, and bounded `Zaik.Home.HistorySummary` aggregates. Environment facts retain named timezone/location calibration and use deterministic sunrise/sunset when latitude/longitude are available, with a labeled configured-hours fallback. Versioned `Zaik.Home.GoalContract` skills declare required evidence and constraints; `Zaik.Home.GoalContextBuilder` independently gathers and freshness-validates that evidence before planning. Read-only `get_area_context` and `get_home_goal_context` expose these deterministic boundaries. Zigbee2MQTT state-file bootstrap restores current state without inserting artificial historical readings.

Accepted canonical observations fan out through the monitored `Zaik.Home.EventBus`; stale and duplicate reports never emit events. `Zaik.Home.OccupancyTracker` composes presence sensors by area, enters immediately, and requires an uninterrupted virtual-time-compatible settle window before declaring vacancy. The autonomy engine subscribes in shadow-only mode, coalesces relevant changes using injected timers, rate-limits evaluations per area, runs event-triggered policy work in bounded monitored `Task.Supervisor` workers, and retains a bounded newest decision window; operator pause/resume and off/shadow/advisory mode changes are explicit, while canary and active execution remain rejected.

Policies are a separate inert decision layer: `Zaik.Home.Policy` modules inspect immutable room context and emit validated `Zaik.Home.GoalCandidate` desired states through an uncached registry. Durable typed `Zaik.Home.Autonomy.ModeStore` leases provide explicit bedtime/privacy context without containing device commands; privacy uses canonical closed-cover semantics, while bedtime requires generic per-device `bedtime` presets so installation-specific airflow positions remain data rather than policy branches. They cannot invoke tools or adapters. Built-in daylight-harvesting and calibrated solar-heat policies default to shadow mode and use persisted desired-state leases for release hysteresis and virtual-time minimum-active windows. Solar-heat comfort authority outranks daylight optimization but remains below privacy/sleep. The reconciler also delays unresolved policy actions through code-owned settle and cooldown windows; event-driven evaluations schedule bounded follow-up wakeups instead of relying on another sensor report, and settle wakeups are reconstructed from active durable leases after an engine restart. `Zaik.Home.Arbitrator` selects one target per entity capability, `Zaik.Home.Reconciler` blocks stale evidence and emits only unresolved inert actions, and `Zaik.Home.Autonomy.ConflictLock` first suppresses equivalent in-flight actions and blocks contradictory targets reported by the physical verifier. Durable `Zaik.Home.Autonomy.ActionBudgetStore` sliding windows then block excessive per-device, per-room, or global autonomous actions before execution. Shadow/advisory assessments do not consume budget. The initial `Zaik.Home.Autonomy.Engine` records this pipeline, including conflict and budget assessments, in a SQLite decision ledger. Structured execution outcomes and rated operator feedback can be appended to that immutable decision identity for evaluation and future training data. Selected semantic targets are also retained as bounded durable leases with source, confidence, evidence, expiry, and supersession history. Durable manual-override leases are attached to room snapshots and suppress background policy candidates until expiry or audited cancellation; accepted explicit home actions automatically create area/capability leases, while autonomy-originated actions are excluded. Canary/active execution is deliberately rejected until operator controls and rollout gates are complete.

Existing `control_blind` and SQL prompts remain as compatibility paths while AgentChat migrates toward typed context and `control_device`.

See [`home-reliability-roadmap.md`](home-reliability-roadmap.md) for the completed reliability foundation and [`zaik-home-brain-roadmap.md`](zaik-home-brain-roadmap.md) for the active continuous-observation, policy, and autonomy roadmap.

## Current status

The codebase still contains some historical names and modules from the original private deployment. The open-source reorganization plan tracks migration toward namespaces such as:

```text
Zaik.Runtime.*
Zaik.Memory.*
Zaik.Brain.*
Zaik.Tools.*
Zaik.Adapters.*
Zaik.Domains.*
```

## Deprecated components

`Zaik.Intent.Parser` is deprecated. Normal free-form chat no longer uses an intent classifier; it routes to `Zaik.AgentChat` instead. The module remains temporarily for legacy tests/experiments.

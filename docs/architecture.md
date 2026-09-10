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

`Zaik.Home.World` projects raw adapter state into stable entities with typed capabilities. `Zaik.Home.Capabilities.Registry` owns semantic state and target validation, while `Zaik.Home.Executors.Registry` maps validated targets to adapter execution. `Zaik.Home.RoomContext` expands a matched entity to its persisted area and combines current entities with deterministic environment facts and bounded `Zaik.Home.HistorySummary` aggregates; `get_area_context` exposes that snapshot for room summaries and future goal/policy evaluation. Zigbee2MQTT state-file bootstrap restores current state without inserting artificial historical readings.

Policies are a separate inert decision layer: `Zaik.Home.Policy` modules inspect immutable room context and emit validated `Zaik.Home.GoalCandidate` desired states through an uncached registry. They cannot invoke tools or adapters. The first built-in daylight-harvesting policy defaults to shadow mode. `Zaik.Home.Arbitrator` selects one target per entity capability, `Zaik.Home.Reconciler` blocks stale evidence and emits only unresolved inert actions, and the initial `Zaik.Home.Autonomy.Engine` records this pipeline in a SQLite decision ledger. Canary/active execution is deliberately rejected until event subscriptions, operator controls, and rollout gates are complete.

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

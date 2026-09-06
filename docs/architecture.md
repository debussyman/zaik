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

`Zaik.AgentChat` can use bounded read tools and validated home actions. Tool and home-capability modules are discovered at runtime through registries that do not cache module code, preserving Elixir's hot-code-loading path. Home actions run in supervised tasks and use a request-scoped SQLite idempotency ledger. Coordinated changes are represented as one `Zaik.Home.ActionPlan`; every action is preflighted before execution and later failures retain structured partial-completion results. `Zaik.Home.ActionVerifier` associates generated action IDs with post-publication Zigbee2MQTT reports, validates capability-specific target convergence, and reconciles later verified results into the action ledger. `Zaik.Home.ActionRetryPolicy` allows an explicit retry only after fresh state proves non-convergence, subject to settle time, cooldown, attempt budget, and capability allowlisting; retry targets are reconstructed from the ledger rather than model arguments. `Zaik.Home.Mirror` runs these same boundaries against isolated virtual entities, presets, state transitions, faults, and desired-state assertions, with `Zaik.Home.Mirror.Executor` replacing physical MQTT execution. Its manually advanced clock drives delayed reports, verifier expiration, timestamps, and retry timing without wall-clock sleeps. Low-risk controls may execute directly; higher-risk capabilities remain intended for proposal/confirmation policy.

### Adapters

External systems should be optional adapters. Current examples include:

- LLM providers: Ollama and llama.cpp/`llama-server`
- messaging: Telegram and legacy Signal
- home automation: MQTT/Zigbee2MQTT

Adapters should translate external protocol details into Zaik's internal APIs without owning core runtime policy.

### Domains

Home automation is one domain built on the harness, not the whole harness. Future domains might include calendar, email, files, finance, or other local personal-agent capabilities.

### Home state and capability boundary

`Zaik.Home.World` projects raw adapter state into stable entities with typed capabilities. `Zaik.Home.Capabilities.Registry` owns semantic state and target validation, while `Zaik.Home.Executors.Registry` maps validated targets to adapter execution. Zigbee2MQTT state-file bootstrap restores current state without inserting artificial historical readings.

Existing `control_blind` and SQL prompts remain as compatibility paths while AgentChat migrates toward `get_home_state` and `control_device`.

See [`home-reliability-roadmap.md`](home-reliability-roadmap.md) for the active stabilization sequence.

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

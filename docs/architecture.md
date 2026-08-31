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
Chat adapter -> Zaik.Ingress.Message -> Zaik.Ingress -> Zaik.ChatRouter -> Zaik.AgentChat -> supervised read-only tools
```

`Zaik.AgentChat` can ask Elixir to run validated read-only SQL against documented views, then answers from tool results. Write/control actions should become human-confirmed proposals before execution.

### Adapters

External systems should be optional adapters. Current examples include:

- LLM providers: Ollama and llama.cpp/`llama-server`
- messaging: Telegram and legacy Signal
- home automation: MQTT/Zigbee2MQTT

Adapters should translate external protocol details into Zaik's internal APIs without owning core runtime policy.

### Domains

Home automation is one domain built on the harness, not the whole harness. Future domains might include calendar, email, files, finance, or other local personal-agent capabilities.

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

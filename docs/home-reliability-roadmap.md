# Home Reliability Roadmap

This roadmap keeps the current house deployment usable while moving from
schema- and device-specific prompting toward typed, composable capabilities.
Phase 3 self-extension is intentionally left open; Zaik's registries avoid code
caches so Elixir hot code loading remains a first-class future option.

## Phase 0: Stabilize action execution

Implemented:

- model fallback is disabled after any home-action attempt, preventing replay
  from the original prompt;
- successful reads and successful actions are tracked separately;
- equivalent successful actions are suppressed within one AgentChat attempt;
- ingress message/update IDs reach the tool execution context;
- home actions run under `Zaik.Tools.TaskSupervisor` with a bounded timeout;
- `Zaik.Home.ActionLedger` provides persistent request/action idempotency;
- action results distinguish broker acceptance from verified physical state;
- `Zaik.Home.ActionPlan` resolves and validates every entity, capability,
  executor, target, and preset before the first side effect;
- multi-action execution reports accepted, verified, failed, or structured
  partial completion without hiding already completed actions;
- Zigbee2MQTT state-file bootstrap no longer manufactures history rows.

Remaining:

- correlate MQTT reports with action IDs and verify target convergence;
- define retry policy for accepted-but-unverified and ambiguous outcomes.

## Phase 1: Canonical home state

Implemented foundation:

- `Zaik.Home.Entity` provides adapter-neutral identity;
- `Zaik.Home.World` projects current adapter payloads into typed state;
- observed time is distinct from process receipt time;
- capability-filtered snapshots prevent unrelated device types from masking
  readings;
- `get_home_state` and `list_devices` are registered typed tools;
- ordinary current-state prompts now require `get_home_state`, while historical
  and trend requests retain the bounded SQL path;
- a composability test verifies that adding Lily's blinds does not alter Lily's
  temperature snapshot.

Remaining:

- persist explicit areas and entity aliases rather than relying on names;
- preserve source observation timestamps throughout every adapter;
- add typed historical queries for capabilities and time windows;
- replace canned SQL eval responses with real temporary SQLite fixture execution;
- clean or mark history rows previously produced by bootstrap.

## Phase 2: Composable capabilities

Implemented foundation:

- `Zaik.Tool`, `Zaik.Home.Capability`, and `Zaik.Home.Executor` behaviours;
- uncached runtime registries for tools, capabilities, and executors;
- generic AgentChat dispatch for newly registered tools;
- `control_device` resolves entity + capability + semantic target before
  adapter execution;
- `execute_home_plan` preflights coordinated actions and is now preferred by
  multi-action home-control prompts and skills;
- cover control is the first capability executor;
- existing `sql_query` and `control_blind` remain compatibility paths.

Remaining:

- generate the planner's available-tool section from registry descriptors;
- migrate remaining skills from device-specific tools to capability targets;
- route existing SQL and blind compatibility calls entirely through generic dispatch;
- enforce skill `allowed_tools` and risk declarations at the execution boundary;
- require capability contract and baseline composability tests for each module;
- make application child composition runtime-configurable by domain/adapter.

## Phase 3: Future self-extension

Pinned for later design. Constraints already established by Phases 1 and 2:

- extensions must register typed tools/capabilities/executors rather than edit
  AgentChat branches;
- safety policy and permissions remain outside model-authored modules;
- registries must preserve hot reloading and avoid stale module caches;
- existing capability and composability tests remain the acceptance boundary.

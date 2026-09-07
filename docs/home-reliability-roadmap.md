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
- `Zaik.Home.ActionVerifier` correlates generated action IDs with later
  Zigbee2MQTT reports and only marks cover targets verified after convergence;
- coordinated plans publish all actions before a shared bounded verification
  wait, and retain child verification IDs for later convergence;
- later verification updates persistent action-ledger results, including the
  aggregate plan status when every child action converges;
- `Zaik.Home.ActionRetryPolicy` permits retries only for low-risk idempotent
  targets after a fresh post-action state report proves non-convergence;
- retry execution enforces a settle window, cooldown, bounded attempt budget,
  and retries only unresolved actions from a coordinated plan;
- `retry_home_action` reconstructs targets from the ledger rather than accepting
  replacement device targets from the model;
- unverified responses expose their correlation ID for status and explicit retry;
- Zigbee2MQTT state-file bootstrap no longer manufactures history rows;
- `get_home_action_status` exposes pending, verified, expired, cancelled, and
  persisted action state to natural-language chat without executing a retry;
- deterministic operator commands can cancel an ambiguous pending action or
  reset its bounded retry budget, with retry resets retained in an audit table.

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
  temperature snapshot;
- live read evals execute against per-run temporary databases created by the
  production home-history and operational-telemetry migrations.

Remaining:

- persist explicit areas and entity aliases rather than relying on names;
- preserve source observation timestamps throughout every adapter;
- add typed historical queries for capabilities and time windows;
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

## Phase 2.5: Mirror-world evaluation and learning foundation

Build a deterministic local digital twin that uses the same entities,
capabilities, tools, plans, verifier, ledger, and retry policy as production,
while replacing physical adapters with virtual executors.

Implemented foundation:

- versionable, fingerprinted scenarios contain areas, entities, presets,
  initial state, desired state, scheduled reports, metadata, and injected faults;
- isolated per-run device, preset, ledger, verifier, task, and mirror stores;
- `Zaik.Home.Mirror.Clock` provides manually advanced wall time and timer queues;
  delayed convergence, verification expiry, ledger timestamps, and retry timing
  can be evaluated without wall-clock sleeps;
- a virtual cover executor uses the production tool, capability, preflight,
  verification, and retry boundaries without any MQTT transport;
- semantic desired-state and maximum-side-effect assertions;
- immediate, delayed, non-converging, transport-failure, and executor-failure
  simulation primitives;
- the live Lily bedtime control eval now executes against the complete mirror
  and asserts the resulting virtual state rather than canned executor output;
- scenarios can declare home-history and operational-telemetry fixtures that
  are loaded through production store APIs into isolated temporary SQLite files;
- the bounded SQL tool accepts internal per-run store/path bindings, so mirror
  reads cannot reach production databases;
- scenario event schedules model source-observed time independently from delivery
  time and retain accepted/stale/duplicate report traces;
- named stale, duplicate, out-of-order, and concurrently conflicting action
  scenarios protect canonical-state and verification invariants;
- stale and duplicate source-timestamped reports cannot regress current state or
  manufacture verification, and conflicting pending targets for one capability
  are rejected before adapter execution.

Remaining:

- replay sanitized production failures and capability changes as scenarios;
- attach capability/tool fingerprints and structured failure labels so passing
  trajectories can later become post-training data;
- gate candidate prompts, adapters, and models on repeated mirror pass rates
  before shadow or physical-canary use.

## Phase 3: Future self-extension

Pinned for later design. Constraints already established by Phases 1 and 2:

- extensions must register typed tools/capabilities/executors rather than edit
  AgentChat branches;
- safety policy and permissions remain outside model-authored modules;
- registries must preserve hot reloading and avoid stale module caches;
- existing capability and composability tests remain the acceptance boundary.

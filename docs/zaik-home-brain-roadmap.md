# Zaik Home Brain Roadmap

## Purpose

Zaik's existing home reliability work provides a safe typed execution boundary:
canonical entities, capabilities, plans, idempotency, convergence verification,
retries, production-schema fixtures, and a deterministic mirror. The next stage
is to turn that reliable request/response foundation into a continuously
observing home brain that can derive context, propose desired state, resolve
competing goals, and reconcile the physical home without automation chatter.

This roadmap supersedes the active planning role of
[`home-reliability-roadmap.md`](home-reliability-roadmap.md), whose Phases 0–2.5
are the completed foundation. It also incorporates the still-relevant work from
[`../open_source_reorganization_plan.md`](../open_source_reorganization_plan.md).

This is not a plan for unrestricted recursive self-modification or online RL.
Model-authored plans remain inside deterministic identity, freshness, permission,
risk, policy, execution, and verification boundaries.

## Target operating model

```text
Adapter observations and explicit user goals
                  |
                  v
      Canonical event and world model
                  |
                  v
 Derived room/environment context and temporal features
                  |
                  v
 Runtime-discovered policies produce candidate goals
                  |
                  v
      Priority and conflict arbitration
                  |
                  v
     Desired-state reconciliation / staged plans
                  |
                  v
 Existing preflight -> executor -> verifier -> ledger
                  |
                  v
 Outcomes, feedback, replay scenarios, and candidate gates
```

Zaik should have two decision paths:

1. **Fast deterministic policy path** for established household preferences,
   debounce, cooldown, safety, reconciliation, and common reactive behavior.
2. **Bounded deliberative model path** for mapping language to goals, resolving
   unfamiliar situations among allowed choices, proposing typed plans, and
   explaining decisions.

The model must not run on every raw sensor report. Accepted observations should
be coalesced into meaningful state changes, and only relevant policies should be
evaluated.

## Principles

- Observations and deterministic derived facts are canonical; model weights are
  not the source of current home truth.
- Policies produce candidate goals or desired state, never MQTT payloads.
- The same entity, capability, target, preset, plan, policy, and verification
  semantics run in production and mirror worlds.
- Expected mirror outcomes must be independently declared rather than computed
  solely through the implementation under test.
- Explicit user actions and temporary manual overrides outrank background
  comfort optimization.
- Safety, privacy, sleep, and permissions outrank convenience and energy goals.
- Reconciliation executes only state differences and enforces hysteresis,
  cooldowns, action budgets, and no-oscillation invariants.
- Missing or stale evidence is represented explicitly and follows a declared
  conservative policy; it is never silently treated as fresh truth.
- Production failures become sanitized replay cases, not ad hoc prompt patches.
- Autonomous operation is enabled incrementally: off -> shadow -> advisory ->
  canary -> active, with rollback at every stage.
- New capabilities and adapters remain runtime-discovered and hot-load-friendly.
- Physical completion is reported only after observed convergence.

## Existing foundation

The following are prerequisites already provided by the completed reliability
roadmap:

- ordered canonical device observations with source and receipt timestamps;
- persisted identity, aliases, areas, history provenance, and generic presets;
- typed current-state and bounded historical tools;
- runtime-discovered tools, capabilities, and executors;
- preflighted coordinated action plans;
- persistent idempotency, action status, cancellation, audited retry reset, and
  policy-gated retry;
- MQTT-backed convergence verification;
- isolated production-schema SQLite mirror fixtures and virtual time;
- mirror faults for delays, non-convergence, transport failure, stale/duplicate
  reports, and conflicting actions;
- tool/capability/scenario fingerprints, failure labels, replay primitives, and
  repeated candidate gates;
- skill allowlist and risk-ceiling enforcement;
- configurable supervision, task resolution, MQTT handlers, shared ingress,
  and provider-neutral LLM clients.

These boundaries should be reused rather than replaced by the autonomy layer.

## Outstanding work folded in from earlier roadmaps

From the home reliability roadmap:

- Phases 0–2.5 are complete and become the execution/evaluation substrate here.
- Its deferred Phase 3 extension boundary is covered by Milestones 10 and 11;
  unrestricted recursive deployment remains excluded.
- Reliability work that becomes more important under continuous autonomy—fresh
  evidence, calibrated adapter semantics, replay automation, generic presets,
  skill authoring, feedback capture, and candidate promotion—is made explicit
  in Milestones 0, 2, 7, 8, and 10.

From the open-source reorganization plan:

- The remaining adapter behaviours and command-processor split are included in
  Milestone 12.
- The complete namespace migration remains outstanding and is included in
  Milestone 12 with compatibility aliases and a stable public facade.
- Contributor examples, CI, issue/security templates, Hex timing, privacy scans,
  private deployment separation, and first-release work remain outstanding and
  are included in Milestone 12.
- New autonomy interfaces should follow the intended runtime, brain, adapter,
  and domain boundaries now, even if bulk renames happen later.

## Milestone 0: Consolidate contracts and independent truth

Goal: remove remaining ambiguity before autonomous decisions depend on it.

- [ ] Define a versioned home-world contract covering entity identity, areas,
  capability state, desired state, freshness, confidence, and provenance.
- [ ] Persist per-entity/per-capability adapter calibration where physical
  orientation or protocol semantics differ; do not rely on one global cover
  assumption for future adapters.
- [ ] Add calibration evidence and operator identity to configuration changes.
- [ ] Use one shared entity-query resolver for current state, history, policies,
  skills, and presets, with metamorphic lookup invariants.
- [ ] Guarantee that every AgentChat attempt and autonomy decision receives a
  durable trace or an observable telemetry-write failure.
- [ ] Record stable observation-snapshot IDs so a decision can identify exactly
  which facts it used.
- [ ] Separate independently declared scenario truth from capability
  normalization used by production execution.
- [ ] Add explicit freshness semantics for state-file bootstrap versus live
  observations.
- [ ] Document household units and conventions, including the current cover
  scale (`0=open`, `100=closed`).

Acceptance:

- A deliberately inverted production implementation fails an independent mirror
  oracle.
- Adding capability, time-window, plural, or question words to a lookup does not
  change the resolved entity set.
- Missing decision traces fail tests and surface operational alerts.

## Milestone 1: Derived room and environment context

Goal: provide compact deterministic facts instead of asking the model to infer
from raw rows.

- [x] Add an initial typed `RoomContext` projection joining entities by persisted
  area and capability.
- [x] Add bounded typed summaries for temperature, humidity, illuminance, and
  presence: first/latest/average/min/max/delta, sample count, window, freshness,
  and provenance. Incremental rolling caches and future energy signals remain.
- [x] Add area-scoped debounced occupancy with confidence and `entered`,
  `occupied`, `possibly_absent`, and `vacant` transitions. Positive evidence is
  immediate, absence requires an uninterrupted configurable settle window, and
  multiple sensors are composed conservatively.
- [ ] Add configured timezone and location bindings. An initial explicit UTC
  offset/host-local fallback is implemented; named-zone and location support
  remains.
- [ ] Derive solar phase from sunrise/sunset and derive a configured season;
  retain the source and timestamp for each fact. Meteorological season and an
  explicitly labeled configured-hours day/night phase are implemented first.
- [x] Add durable manual-override leases with owner, area/home scope, optional
  capability, reason, start, expiry, cancellation audit, and context evidence.
- [x] Expose one generic typed `get_area_context` tool for an area and requested
  historical facts.
- [x] Emit accepted canonical state-change events through a monitored local bus
  without emitting stale or duplicate observations.
- [x] Coalesce noisy observations by area under injected time, union changed
  capability dependencies across each burst, and evaluate only affected policies.

Acceptance:

- A context snapshot can state that a room is occupied, dark, cool, daytime, in
  summer, and has closed covers without model arithmetic or SQL generation.
- Sparse history and stale sensors produce explicit quality/freshness fields.
- Virtual time deterministically drives windows, solar transitions, debounce,
  and override expiry.

## Milestone 2: Declarative goals, skills, and household preferences

Goal: turn prose skills into validated goal contracts while preserving flexible
natural-language invocation.

- [x] Version the skill schema with goal ID, scope, required observations,
  preferences, constraints, allowed tools, risk ceiling, and missing-data policy.
- [ ] Keep semantic goal recognition model-driven; do not add phrase-specific
  command branches for expressions such as "It's Lily's bedtime."
- [x] Add a deterministic `GoalContextBuilder` that loads a matched semantic
  goal skill and gathers environment, history, capabilities, occupancy, and
  scoped presets before planning.
- [x] Require planners to return typed semantic goal IDs, capability actions,
  and stable evidence fingerprints without exposing hidden chain-of-thought;
  Elixir rebuilds evidence and rejects omitted, invented, or changed references.
- [x] Validate evidence freshness and required observations before execution:
  versioned-goal actions must use one coordinated plan carrying the exact stable
  goal-context fingerprint, which is rebuilt and compared before preflight.
- [x] Add generic `apply_device_preset` and `capture_device_preset` tools;
  captured targets come only from fresh canonical capability state and applying
  a preset re-enters normal target validation and supervised execution.
- [ ] Add proposal/confirmation-based natural-language skill authoring and
  reject unvalidated direct skill writes.
- [x] Define validated missing-data behavior: block by default, optionally ask
  for clarification, or explicitly return a degraded non-executing context.

Initial Lily bedtime contract:

```text
goal: lily_bedtime
required facts:
  local solar phase, season, recent room-temperature summary,
  current cover positions, available cover presets
household preference:
  when cooling airflow should remain unobstructed,
  left blind -> 100 and right blind -> preset "above AC" (71)
```

Acceptance:

- "It's Lily's bedtime" and diverse paraphrases resolve to the same semantic
  goal and independently gathered context.
- Missing or stale context cannot be presented as observed fact.
- Already-satisfied targets produce zero unnecessary side effects.

## Milestone 3: Runtime policy engine

Goal: let established household policies continuously produce candidate desired
states without directly controlling devices.

- [x] Introduce a hot-load-friendly `Zaik.Home.Policy` behaviour with descriptors,
  dependencies, candidate-goal output, and validation contracts.
- [x] Add an uncached runtime policy registry and fingerprints.
- [x] Define a candidate-goal schema containing scope, desired state, priority,
  evidence, calibrated confidence, expiry, reason, and policy version, with
  capability validation, stable IDs, and fingerprints. Confidence deterministically
  breaks ties only within the same household priority.
- [ ] Implement initial generic policies:
  - [x] shadow-first daylight harvesting;
  - [ ] bedtime/privacy comfort;
  - solar-heat avoidance;
  - occupancy lighting after light capabilities exist;
  - absence-based lighting shutdown.
- [ ] Policies must depend on area/capability contracts rather than household
  device names.
- [ ] Add hysteresis and minimum-active/settle periods to policy descriptors.
  Descriptors now require hysteresis, minimum-active, settle, and cooldown
  declarations; daylight release hysteresis and minimum-active enforcement are
  implemented, while generic settle/cooldown enforcement remains.
- [x] Evaluate observation-triggered policies only when their declared capability
  dependencies changed; explicit evaluations still run the complete registry.
- [ ] Keep model consultation optional and bounded for ambiguous candidate
  selection; deterministic policies handle established preferences.

Daylight-harvesting example:

```text
if occupied + daytime + low illuminance + room cool enough + covers closed
then candidate goal: increase natural light by opening covers
unless suppressed by bedtime, privacy, heat, or a manual override
```

Acceptance:

- A policy emits a candidate and evidence but cannot invoke an executor.
- Adding a compatible room automatically makes a generic policy evaluable.
- [x] Sensor noise within the daylight release band cannot repeatedly activate
  and deactivate a candidate; virtual time covers minimum-hold expiry.

## Milestone 4: Arbitration and desired-state reconciliation

Goal: choose one explainable desired state when policies and people disagree.

- [x] Define fixed, non-model-selected household priority classes:
  safety/security > explicit user/manual override > privacy/sleep > comfort >
  daylight/energy optimization. Candidate numeric weights must match their class.
- [x] Add deterministic priority arbitration per entity capability.
- [x] Record selected and suppressed candidates with expired, equivalent, or
  conflicting reasons.
- [x] Add a bounded durable desired-state lease store with source/version,
  priority class, confidence, target, evidence, snapshot, expiry, decision ID,
  and policy-registry fingerprint; conflicting active leases are superseded.
- [x] Diff selected desired state against fresh canonical observations, blocking
  missing or stale state.
- [x] Skip converged targets and emit inert action arguments only for unresolved
  differences.
- [ ] Enforce per-device, per-room, and global action-rate budgets.
- [ ] Prevent oscillation through hysteresis, settle windows, cooldowns, and
  conflict locks.
- [x] Preserve explicit action-plan preflight, idempotency ledger, physical
  verifier, and policy-gated retry boundary; successful explicit actions also
  create area/capability override leases so background goals cannot undo them.
- [ ] Add autonomy modes globally and per policy/room: off, shadow, advisory,
  canary, active.

Acceptance:

- Bedtime suppresses daylight harvesting with a recorded explanation.
- A temporary manual close is not immediately undone by background automation.
- Equivalent desired states from multiple policies result in at most one action.
- Restart recovery does not replay a converged or ambiguous side effect.

## Milestone 5: Supervised autonomy loop and decision ledger

Goal: run observation-to-reconciliation continuously under OTP supervision.

- [x] Add a supervised shadow/advisory autonomy event coordinator rather than
  polling process lists or spawning untracked model calls; execution modes remain
  deliberately unavailable pending rollout gates.
- [ ] Subscribe it only to accepted canonical changes and explicit user goals.
  Production shadow observation subscription, area/dependency filtering, and
  explicit operator evaluation are implemented; semantic user-goal ingestion remains.
- [x] Coalesce area bursts, union changed dependencies, enforce a configurable
  minimum interval, and execute event-triggered policy evaluations in bounded,
  monitored `Task.Supervisor` workers with timeouts; explicit operator calls
  remain synchronous by design.
- [ ] Add durable decision IDs and a SQLite decision ledger containing snapshot,
  candidates, arbitration, plan, outcomes, and feedback. The initial ledger now
  stores a bounded newest window of context, candidates, arbitration, and
  reconciliation; execution outcomes and feedback remain.
- [ ] Correlate every physical action with its originating decision, goal,
  policy, and observation snapshot.
- [ ] Add watchdog recovery for stuck evaluations and staged plans.
- [x] Expose operator status, global pause/resume, safe runtime mode changes,
  manual suppression leases, desired-state inspection, and recent decisions;
  canary/active modes remain impossible.
- [ ] Add alerts for repeated non-convergence, oscillation prevention, stale
  critical inputs, and telemetry failures, with cooldown/debounce.

Acceptance:

- Zaik can run for an extended virtual period with bounded processes, timers,
  actions, and database growth.
- Every action has an explainable causal chain from observation or explicit goal
  through verification.

## Milestone 6: Conditional and staged plans

Goal: support decisions where one action changes whether another is necessary.

- [ ] Extend action planning with stages, typed conditions, deadlines,
  observation waits, cancellation, and durable restart recovery.
- [ ] Do not allow arbitrary model-authored code or predicates; conditions use
  registered capability comparisons.
- [ ] Re-evaluate canonical state between stages.
- [ ] Preserve complete preflight for each stage before its first side effect.
- [ ] Define safe behavior for partial completion and expired goals.
- [ ] Reuse verifier and retry policy for each child action.

Initial lighting workflow:

```text
1. If occupied, daytime, dark, and cool, open the covers.
2. Wait for cover convergence and an illuminance settle window.
3. If the room remains dark and is still occupied, turn on the lights.
4. If presence becomes stale or the goal expires, cancel remaining stages.
```

Acceptance:

- Lights are not switched on unnecessarily while opening covers may supply
  enough daylight.
- A failed cover action cannot silently advance to an invalid later stage.

## Milestone 7: Temporal mirror, generated coverage, and replay

Goal: make the mirror a continuous autonomy simulator and coverage generator,
not only a collection of hand-written examples.

- [ ] Run the policy engine, arbitration, reconciliation, staged plans, and
  decision ledger under the existing virtual clock. Daylight policy through
  inert reconciliation and an isolated decision ledger is now covered with zero
  side effects; temporal staged plans remain.
- [ ] Add independent physical-semantics fixtures and adapter calibration
  variants.
- [ ] Generate scenario matrices across day/night, season, occupancy, light,
  temperature, current device state, freshness, overrides, and faults. The
  daylight boolean matrix, override-expiry timeline, debounced occupancy
  timeline, and independently gathered goal evidence are covered; broader
  generated combinations remain.
- [ ] Add metamorphic natural-language and tool-argument generation for aliases,
  possessives, plurals, word order, capability words, and time phrases.
- [ ] Assert lookup invariance between current and historical tools.
- [ ] Add sparse-window scenarios where 30 minutes is empty but 3 hours contains
  valid data.
- [ ] Automatically convert sanitized production failures and operator
  corrections into reviewable replay candidates.
- [ ] Require approved replay cases to remain in a durable regression corpus.
- [ ] Add cold/unloaded-model and normalized Telegram-ingress integration tests.
- [ ] Run model cases repeatedly and record pass-rate distributions, not only one
  generation.
- [ ] Assert safety and liveness invariants: maximum side effects, no forbidden
  tools, no unverified completion claims, no oscillation, eventual convergence
  where possible, and respect for overrides.

Required initial temporal scenarios:

- Lily bedtime: open blinds, summer, nighttime, recent temperature around 76°F.
- Daylight harvesting: occupied, daytime, low light, cool room, closed blinds.
- Heat conflict: occupied and dark but direct-sun/temperature policy suppresses
  opening.
- Bedtime conflict: daylight policy is active when an explicit bedtime goal
  arrives.
- Sparse temperature history: recent window empty, wider window valid.
- Noisy presence: repeated reports do not create action chatter.
- [x] Manual override: automation remains suppressed until virtual expiry, with
  zero mirror side effects and the lease retained as snapshot evidence.
- Staged daylight/lighting: lights remain off if opening covers raises lux.

Acceptance:

- Known production lookup, time-window, model-load, ordering, and cover-calibration
  regressions fail before deployment when reintroduced.
- Safety invariants pass on every generated case; configured quality thresholds
  pass over repeated model runs.

## Milestone 8: Shadowing, canaries, promotion, and rollback

Goal: deploy autonomy without granting immediate broad physical control.

- [ ] Run candidate policies and models against production observations in
  shadow mode with MQTT and production writes disabled.
- [ ] Compare candidate desired state and decisions with the active policy.
- [ ] Provide concise operator explanations and approval controls.
- [ ] Require repeated mirror gates, replay gates, and a minimum shadow duration
  before canary eligibility.
- [ ] Permit only explicitly allowlisted low-risk canary capabilities and rooms.
- [ ] Require zero safety failures; keep quality thresholds configurable and
  versioned.
- [ ] Persist promotion evidence and operator identity.
- [ ] Support immediate policy/model rollback without changing capability or
  physical adapter configuration.
- [ ] Keep higher-risk actions behind proposal/confirmation regardless of model
  quality.

Acceptance:

- A candidate cannot publish production MQTT in mirror or shadow modes.
- Promotion and rollback are deterministic, durable, inspectable, and tested.

## Milestone 9: Lighting and broader capability composition

Goal: prove that the autonomy architecture generalizes beyond covers.

- [ ] Add typed switch, dimmer, brightness, and color-temperature capabilities.
- [ ] Add validated executors and convergence semantics for the selected smart
  lighting adapter.
- [ ] Associate lights with persisted areas and generic policies.
- [ ] Add occupancy-lighting and absence-shutdown policies with debounce,
  cooldown, and manual overrides.
- [ ] Add cover-first daylight workflows.
- [ ] Extend composability tests so lighting reports cannot alter temperature,
  occupancy, or cover state.
- [ ] Add energy, HVAC, weather, door/window, and safety capabilities only through
  the same contracts in later slices.

Acceptance:

- Adding a compatible light changes runtime contracts immediately without an
  AgentChat branch or mandatory model retraining.
- Lighting automation passes temporal mirror, shadow, override, and
  no-oscillation gates before activation.

## Milestone 10: Learning and preference improvement

Goal: improve semantic planning from evidence without allowing models to replace
canonical state or policy.

- [ ] Build `Zaik.Learning.DatasetBuilder` for privacy-filtered JSONL trajectories,
  corrected plans, outcomes, and feedback.
- [ ] Capture Telegram reactions and explicit corrections as labeled feedback.
- [ ] Generate synthetic planning examples from capability, policy, and skill
  contracts.
- [ ] Register candidate models/adapters with immutable fingerprints.
- [ ] Train isolated LoRA/SFT candidates first for goal resolution and typed plan
  reliability.
- [ ] Consider preference optimization only after sufficient reviewed feedback.
- [ ] Consider GRPO only when the calibrated temporal mirror supplies broad,
  deterministic, independently checked rewards and robust anti-reward-hacking
  tests.
- [ ] Keep learned occupancy, temperature, travel-time, or failure predictors
  advisory; they cannot overwrite observations or execute actions.
- [ ] Prohibit unrestricted online weight updates and recursive deployment.

Potential executable reward components for a future offline planner candidate:

- semantic desired state reached;
- no unnecessary or forbidden side effects;
- required fresh evidence gathered;
- permissions, risk, override, and action budgets respected;
- no false physical-completion claim;
- concise correct explanation;
- no oscillation over the complete episode.

RL/GRPO is explicitly not a prerequisite for Milestones 0–9. Training against
an incomplete or circular mirror would optimize the model toward simulator bugs.

## Milestone 11: Safe extension boundary

Goal: preserve Elixir hot loading while preventing unrestricted self-deployment.

- [ ] Define versioned extension manifests for tools, capabilities, executors,
  policies, and skills.
- [ ] Run contract, composability, permission, mirror, and replay gates in an
  isolated candidate environment.
- [ ] Require operator approval before enabling model-authored or externally
  supplied executable extensions.
- [ ] Keep safety policy, credentials, promotion, and rollback outside extension
  authority.
- [ ] Retain uncached runtime registries while making load/unload status
  observable.
- [ ] Never allow a model to bypass review by editing registry configuration or
  promotion evidence.

This folds in the deliberately deferred Phase 3 boundary from the reliability
roadmap without authorizing recursive production changes.

## Milestone 12: Complete outstanding OSS reorganization

Goal: make the autonomy architecture reusable and understandable without tying
it to one private household.

Boundary work:

- [ ] Add a messaging-adapter behaviour and a home bridge/observation-adapter
  behaviour; existing LLM, tool, MQTT-handler, capability, and executor
  behaviours remain the starting point.
- [ ] Split the monolithic command processor into domain command modules.
- [ ] Complete namespace migration in reversible slices with compatibility
  aliases:
  `Zaik.Runtime.*`, `Zaik.Memory.*`, `Zaik.Storage.*`, `Zaik.Brain.*`,
  `Zaik.Adapters.*`, and `Zaik.Domains.Home.*`.
- [ ] Keep the public `Zaik` facade stable and keep the project a single Mix app.
- [ ] Update architecture and module-map documentation after each migration.

Contributor and launch work:

- [ ] Add minimal runtime, custom task, custom messaging adapter, Telegram,
  Zigbee2MQTT, and local-LLM examples.
- [ ] Add CI running format checks, full tests, routing evals, and deterministic
  mirror evals without private services or data.
- [ ] Add issue templates and security policy/notes.
- [ ] Decide Hex publication timing and package metadata expectations.
- [ ] Complete tracked-file and history scans for credentials, phone numbers,
  chat IDs, local addresses, and private household defaults.
- [ ] Keep private deployment configuration outside the public repository.
- [ ] Decide on a code of conduct, tag the first public release, and publish
  contributor-facing launch documentation.

Namespace migration and public packaging must not block safety work, but new
interfaces introduced by this roadmap should follow the target layer boundaries
so the eventual migration does not create a second architecture.

## Recommended execution order

```text
0  contracts and independent truth
1  derived context
2  declarative goals/skills
3  policy engine
4  arbitration/reconciliation
5  supervised autonomy loop
7  temporal mirror/generated coverage (developed alongside 1–5)
6  staged plans
8  shadow/canary rollout
9  lighting composition
10 learning candidates
11 safe extension boundary
12 remaining OSS namespace/examples/release work
```

Milestone 7 is intentionally parallel: every new context, policy, arbitration,
or workflow feature must add mirror scenarios and invariants in the same change,
not after the runtime implementation is considered complete.

## First vertical slice

The first production-shaped slice should implement two goals without activating
background control:

1. **Explicit Lily bedtime goal**
   - Resolve natural-language paraphrases to `lily_bedtime`.
   - Gather current covers, three-hour temperature summary, season, solar phase,
     and presets.
   - Produce left `100`, right `above AC`/`71` when the cooling preference
     applies.
   - Skip satisfied targets and verify remaining actions.

2. **Shadow-only daylight harvesting**
   - On a debounced room-entry or meaningful light change, evaluate occupancy,
     daylight, illuminance, temperature, cover state, bedtime/privacy state, and
     overrides.
   - Record whether covers would be opened, but publish no MQTT.
   - Replay the decision under virtual time and generated conflict scenarios.

Only after the shadow decision ledger is accurate and stable should daylight
harvesting receive a low-risk physical canary.

## Definition of home-brain v1

Home-brain v1 is complete when:

- explicit goals and accepted state changes both enter the same supervised
  decision pipeline;
- derived context is typed, timestamped, and reproducible;
- runtime policies produce explainable candidate goals;
- arbitration and manual overrides prevent conflicting automation;
- reconciliation is idempotent, rate-limited, verified, and restart-safe;
- Lily bedtime and daylight harvesting pass generated temporal scenarios and
  repeated model evals;
- production shadow decisions are durable and inspectable;
- one explicitly approved low-risk autonomous policy completes a physical canary
  without violating safety or chatter invariants;
- rollback is demonstrated;
- no model can publish unrestricted payloads, modify canonical observations,
  evade policy, or promote itself.

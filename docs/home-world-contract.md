# Home-world units, semantics, and provenance

Zaik's canonical home world is versioned by `Zaik.Home.WorldContract`. The
runtime contract and fingerprint are available through:

```elixir
Zaik.home_world_contract()
```

This document describes the human-facing conventions behind that executable
contract. Adapter payloads must be normalized and validated before code relies
on these meanings.

## Capability units

| Capability | Canonical representation | Convention |
| --- | --- | --- |
| Cover position | integer `0..100` | `0` is fully open; `100` is fully closed. Intermediate values increase toward closed. |
| Cover state | `OPEN`, `CLOSE`, or `STOP` | Endpoint state is derived from canonical position where available. Adapter state is retained separately. |
| Temperature | Celsius and Fahrenheit numbers | Zigbee2MQTT temperature input is Celsius. Canonical state exposes both Celsius and Fahrenheit; historical storage uses Celsius. |
| Humidity | number | Relative humidity percentage (`0..100`). |
| Illuminance | number | Lux for policies that use illuminance thresholds. An adapter whose reported value is not lux requires explicit typed normalization before policy use. |
| Presence | boolean | `true` means detected by that entity. Area occupancy is a separate derived projection. |
| Battery | number | Adapter-reported percentage when available. Missing battery data remains missing and is never synthesized. |
| Link quality | number | Adapter-specific link-quality score, not a percentage and not comparable across adapter families without calibration. |

The household cover convention is intentionally fixed:

```text
0   = fully open
100 = fully closed
71  = Lily's right blind above the AC (a stored household preset, not a global semantic)
```

Installation-specific positions belong in evidence-backed calibration or named
device presets, never policy source code.

## Time and freshness

- `observed_at` is the only freshness reference.
- `received_at` records canonical-store acceptance and never substitutes for an
  observation timestamp.
- `source_observation` is freshness-eligible.
- `bootstrap_recovery` and `unobserved` are not freshness-eligible.
- Times are represented as ISO-8601 UTC timestamps at public boundaries.
- Stale and duplicate source reports do not mutate canonical state.

## Desired state and confidence

Desired states are inert semantic targets. They are not MQTT payloads and do
not authorize execution. Every selected desired state carries policy identity,
policy version, candidate identity, priority class, bounded confidence,
evidence, reason, and expiry.

Confidence is constrained to `0.0..1.0`, rounded to three decimal places, and
must cite both:

- the exact evidence `snapshot_id`; and
- a code-owned `confidence_source` describing how confidence was calibrated.

Confidence ranks candidates only within the fixed authority order. It can never
override safety/security, explicit-user, privacy/sleep, comfort, or
daylight/energy priority classes.

## Provenance

Canonical observations retain adapter source, observation classification,
observation time, and receipt time. Desired states retain policy and evidence
provenance. Adapter calibrations retain operator identity, reason, independent
evidence fingerprint, and append-only revision.

A world snapshot ID hashes its world-contract fingerprint and exact ordered
public entity facts. Generation time is excluded, so unchanged facts retain the
same identity.

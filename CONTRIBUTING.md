# Contributing to Zaik

Thanks for your interest in Zaik. This project is an Elixir/OTP local-first personal agent harness with optional adapters for local LLM providers, messaging surfaces, and home automation systems.

## Development setup

Use the Nix development shell when possible:

```bash
nix develop
```

Run the test suite:

```bash
nix develop -c mix test
```

Run the app locally:

```bash
nix develop -c mix run --no-halt
```

## Contribution guidelines

- Keep core runtime code independent from personal deployments and specific home setups.
- Prefer explicit behaviours/adapters for integrations with external services.
- Keep adapters optional and configurable through application env or environment variables.
- Do not commit private env files, bot tokens, phone numbers, chat IDs, local database files, or household-specific data.
- Add or update tests for behaviour changes.
- Keep `nix develop -c mix test` passing.

## Architecture direction

See:

- [`open_source_reorganization_plan.md`](open_source_reorganization_plan.md)
- [`docs/architecture.md`](docs/architecture.md)

The high-level direction is:

```text
Core runtime is generic.
Memory is local-first and inspectable.
Adapters are optional.
Domains are pluggable.
The normal chat brain is externally unified.
Dangerous writes/control actions require confirmation.
```

## Private runtime config

Use local files such as:

```text
~/.config/zaik/telegram.env
~/.config/zaik/signal.env
```

Example files are provided under [`examples/env/`](examples/env/). Do not commit real copies.

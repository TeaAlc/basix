# ADR 0019: Native agent model overrides

## Status
Active

## Context
The user requests Terra low for Luna agents above medium.

## Decision
Supersedes ADR 0008. Replace native Luna agents above medium with explicit `gpt-6.1-terra`/low overrides: Pager and Verifier. Explorer remains Luna/low, Researcher Luna/medium, Miraculix Astra/low. Roles and sandbox rules remain.

## Consequences
Agent definitions, validator, tests and documentation enforce these settings.

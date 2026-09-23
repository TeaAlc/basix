# ADR 0008: GPT-6 agent models

## Status
Active

## Context
Basix agent models need a GPT-6 default and a stronger Miraculix model.

## Decision
Supersedes ADR 0002. Native agents use `gpt-6-luna` at their classified effort. Miraculix uses explicit `gpt-6-astra`/low; its bounded consultation rules remain.

## Consequences
Authoring policy, validator, tests, and documentation enforce the new models.

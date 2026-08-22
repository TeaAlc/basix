# ADR 0002: Miraculix bounded consultation

## Status
Active

## Context
Uncertainty can warrant a bounded second opinion.

## Decision
Add read-only junior `basix_miraculix` with explicit `gpt-5.6-sol`/low. Fresh spawns receive a full goal and questions totaling at most 1024 characters. They use no domain sources and answer within 1024 characters or state doubt exactly.

## Consequences
Seniors and principals may consult it. The parent owns topic continuity; new topics require fresh agents.

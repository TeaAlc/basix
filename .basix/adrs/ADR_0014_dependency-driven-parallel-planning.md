# ADR 0014: Dependency-driven parallel planning

## Status
Active

## Context
Independent work needs explicit acceptance and integration.

## Decision
Dependencies govern readiness; joins await named accepted results. Isolate parallel writes and resources. Git writers use feature branches/worktrees. Root owns scoped checkpoints and tested, frozen integration before target update.

## Consequences
Keep general planning tool-neutral; load Git and optional report details only when needed.

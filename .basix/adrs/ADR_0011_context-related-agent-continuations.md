# ADR 0011: Context-related agent continuations

## Status
Active

## Context
Fresh agents discard useful context for fixes and related follow-ups.

## Decision
Contract 2.0 permits direct-parent-authorized reuse for fixes and context-related follow-ups. The parent updates scope, ownership and criteria explicitly. Each verification cycle freezes its target. Unrelated work uses a fresh agent.

## Consequences
Continuation policy lives in the contract; native roles retain their boundaries.

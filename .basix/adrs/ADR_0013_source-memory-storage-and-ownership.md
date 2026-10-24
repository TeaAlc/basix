# ADR 0013: Source memory

## Status
Active

## Context
Research should retain useful sources without granting researchers writes.

## Decision
Store project-owned catalogs in .basix/sources/sources.toml and categories.toml.
An authorized parent merges read-only observations. Preserve fixed category
meanings, scoped justified trust changes, and retry-safe usefulness events.

## Consequences
Installers preserve catalogs; local writes use locking and atomic replacement.

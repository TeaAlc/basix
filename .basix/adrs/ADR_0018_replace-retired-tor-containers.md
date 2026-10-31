# ADR 0018: Replace retired Tor containers

## Status
Active

## Context
Only the new secure runtime is supported.

## Decision
Remove positively identified Basix-owned retired Scrapling/Tor containers and create the strict current runtime. Do not migrate, preserve running legacy snapshots, or restore retired containers. Protect foreign resources. Reuse only exact current configurations.

## Consequences
Recovery removes failed new resources or reinstalls reviewed code; no legacy compatibility mode.

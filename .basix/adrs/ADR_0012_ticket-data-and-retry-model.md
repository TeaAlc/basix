# ADR 0012: Ticket data and retry model

## Status
Active

## Context
Ticket creation needs durable service-independent recovery.

## Decision
Use basix-ticket-management: coordinator-owned .basix/tickets metadata for created tickets, service mapping and full failed drafts. Preserve identity and creation time. Allow five retries at 5m, 30m, 2h, 12h, 48h intervals after prior attempts, only while the incident persists and work is authorized.

## Consequences
No background retries; tools own service access.

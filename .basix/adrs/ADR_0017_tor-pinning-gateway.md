# ADR 0017: Tor pinning gateway

## Status
Active

## Context
SafeSocks rejects ordinary numeric CONNECT, conflicting with download pinning.

## Decision
Retain SafeSocks. A trusted Tor-side gateway accepts only public numeric targets and uses control MAPADDRESS virtual mappings for pinned connections. Control credentials stay in the Tor container. Bound streams and reference-count shared mappings; remove unused mappings.

## Consequences
Downloads require the gateway; other proxies stay separate.

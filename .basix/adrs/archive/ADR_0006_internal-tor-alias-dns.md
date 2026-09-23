# ADR 0006: Internal Tor alias DNS

## Status
Superseded by ADR 0007.

## Context
Numeric Tor addresses break Scrapling after sidecar replacement.

## Decision
Use only managed peer alias `basix-tor-proxy` on a DNS-enabled internal network. Configure no upstream DNS or direct Scrapling egress. Prove alias-only isolation before migration and fail closed when unprovable.

## Consequences
Tor IP changes are transparent. Unsupported runtimes exit before mutation; numeric fallback is forbidden.

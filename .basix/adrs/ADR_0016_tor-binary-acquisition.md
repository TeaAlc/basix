# ADR 0016: Tor binary acquisition

## Status
Active

## Context
Scrapling extraction lacks binary export.

## Decision
Use client-owned bounded jobs, Tor remote resolution with validated pinned destinations, verified TLS, and atomic hash-checked artifacts. Export only through an administrator-confined local channel. No direct fallback or unsafe resume. Preserve ADR 0007's DNS exception and report its acceptance gaps.

## Consequences
Consumers use acquired assets offline.

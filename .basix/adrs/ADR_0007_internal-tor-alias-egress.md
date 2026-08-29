# ADR 0007: Internal Tor alias egress

## Status
Active; supersedes ADR 0006.

## Context
Podman 4.9.3 cannot guarantee peer aliases and external DNS NXDOMAIN.

## Decision
Use managed alias `basix-tor-proxy` with no explicit upstream DNS and forbid direct Scrapling egress. External DNS answers may occur; application HTTP DNS must use SOCKS5h through Tor.

## Consequences
DNS metadata can reach host resolvers. Alias and direct-TCP isolation are proven before mutation; numeric fallback remains forbidden.

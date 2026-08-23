# ADR 0004: Project local access permissions

## Status
Active

## Context
Project sandbox access needs purpose-based, independent controls.

## Decision
Supersedes ADR 0003. The project installer manages opt-in `local-network` for loopback networking (for example Playwright) and `test-socket` for only canonical `<repo>/test/test.sock`. Global installs remain unchanged.

## Consequences
CLI choices compose explicitly; exact legacy Playwright settings may migrate; changes require a new Codex session.

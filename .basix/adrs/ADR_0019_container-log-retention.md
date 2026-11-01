# ADR 0019: Container log retention

## Status
Active

## Context
Container logs must expire within 15 minutes, including stopped services.

## Decision
Retain no container log content: disable runtime log storage, remove Tor file logging, and silence healthcheck output. Keep health status and explicit local diagnostic probes. Recognize owned prior configurations for replacement; preserve foreign resources.

## Consequences
Zero retention satisfies the bound without a cleanup timer.

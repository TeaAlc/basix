# ADR 0015: Plan executor capacity

## Status
Active

## Context
Feature plans need bounded research capacity.

## Decision
Supersedes ADR 0010. Model/effort: user, specialist/skill, gpt-6.1-sol/low. No forks. Contract2.0: blockers and mandatory final send_message; wait 1800000 ms. Max 3 plan executors, each with 2 RO exploration/research children; max 6 RO and 9 descendants overall, subject to runtime limits. Root may request material efficiency analysis.

## Consequences
Native defaults stay unchanged.

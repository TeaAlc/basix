---
name: basix-planning
description: "Basix-Skill: Use before creating, revising, executing, completing, or archiving a saved phase plan."
---

# Basix Planning

Read the complete `basix` router first. Follow its active-instruction precedence,
spawn authority, and mandatory management boundary for managed assignments.
Before planning, read [basix-adr](../basix-adr/SKILL.md) completely, then the
active ADR index and only relevant active ADRs; active ADRs are binding.
Saved phase plans and Contract 2.0 message streams are distinct requirements;
plans are not transmitted and cycle revisions remain contract-owned.

- Structure every plan as clearly bounded phases serving one explicit overall goal. Make phases as independent and self-contained as practical, and state required dependencies.
- Define each phase briefly and in this order:
  - **Goal:** Required end state.
  - **Work:** Numbered planned work items labeled **Task 1:** through **Task n:** in execution order, including dependencies. Ordered under each other as markdown list.
  - **QS:** Concrete completion checks.
  - **Learnings:** Leave this field empty when creating a phase. Populate it only after that phase's QS succeeds and only with findings relevant to later phases; do not use placeholder text such as `Pending`; assess durable insights for `memory.toml` and retain qualifying ones under the memory rules.
- Order work for maximum input-token efficiency without compromising correctness, safety, or mandatory dependencies. Delegate token-intensive, bounded work when its result outweighs the added context, marking the Tasks  with `(Subagent Task: <subagent_type>)`.
- Save every new plan as `.basix/plans/<stem>-NNN.md`, where `NNN` is a canonical decimal suffix of at least three digits, zero-padded to a minimum width of three without redundant leading zeros, starting at `001` (for example `001`, `010`, `999`, `1000`; not `000`, `01`, or `0001`). Before saving, inspect only direct files in the active `.basix/plans/` directory and `.basix/plans/archive/`; ignore other nested directories. Define the logical stem by removing a final `-NNN.md` from the basename.
- If no matching numbered file exists for that stem, use `001`; otherwise use one greater than the highest existing valid suffix. Never reuse a lower number or overwrite any existing path. Existing unsuffixed plans are legacy: do not rename them, but never create another unsuffixed plan; a new plan with that stem starts at `001` unless numbered successors exist. Treat malformed suffixes as legacy, preserve them, and exclude them from numbering without silently overwriting them. Number each logical stem independently.
- Move a replaced or completed plan to `.basix/plans/archive/` with its exact numbered basename. After each phase, update the remaining plan from its results. At each phase, change affected parts when new evidence can reduce risk, improve quality or workflow, save work, or materially reduce tokens; keep the overall goal authoritative.
- Estimate total effort before work begins. Above 10 million expected input tokens for the whole plan, ask whether to compact after every phase. If enabled, each phase closure must preserve, compactly but completely, everything needed to continue: findings, decisions, dependencies, and discovery results.
- When files needed to fix a bug or add a feature are discovered, list every affected file in the plan with a work description of at most 32 characters.

Before retaining durable phase learnings in memory, read and follow
[basix-agent-memory](../basix-agent-memory/SKILL.md) completely.

## Delegated execution and recovery

Root delegates saved-plan execution using management's model/effort selection
precedence: explicit user override, applicable specialist/skill settings, then
`gpt-6.1-sol`/`low` runtime fallback for each unspecified field independently.
A model-only user override retains applicable effort. Saved plans do not replace
native specialist routing or configured model/effort; generic executors receive
the fallback only when no more explicit setting applies. Always use
`fork_turns="none"`; unsupported selected settings block dispatch without substitution.
Follow management's complete assignment and three-active-slot
rules; independent phases may run together only with independent dependencies,
disjoint ownership and isolated resources. Dependent phases wait for acceptance.
Root owns approval/ADRs, dispatch, review, archival and commit; executor ownership
covers only assigned implementation, checks, plan checkpoints and requested analysis.

Before compaction, save minimal continuation state in the assigned plan/checkpoint:
task/goal, next steps, owned scope/resources/permissions, decisions, completed QS
and log paths, pending blockers, report flag, contract version, logical sequence
and cycle revision. Never use memory for transient state. Resume without a plan or
status message and without a context fork. Learnings still require successful QS.

## Optional material efficiency analysis

Root explicitly decides whether analysis is required, normally at dispatch;
there is no compulsory report for every task. For `foo-001.md`, the exact adjacent
companion is `foo-001_efficency_analysis.md`: preserve this spelling and full
numbered basename. A companion is not a numbered plan. Root grants explicit write
ownership for the exact plan/report paths, including `.basix/`; read-only context
permission does not grant writes and read-only specialists remain read-only.

Before dispatch root resolves any pre-existing report with explicit authorized
update/merge or preservation, retaining prior material findings and task/cycle
attribution. Never overwrite a different artifact or invent another suffix.
Archive or replace the plan and companion together preserving both basenames;
check both destination collisions before moving either. Respect ignore rules.
An explicitly requested analysis artifact is not a file solely for handoff.

Analyze only material evidenced negative drivers and substantial reusable
improvements: cause, evidence, effect on work, intervention, likely benefit and
uncertainty, and practical verification. Positive factors belong only when they
support a substantial reusable improvement. Use lightweight existing logs and
attributable telemetry, never broad rollout ingestion or new monitoring merely
to fill a report. Metrics cover only the assigned task/cycle and eligible
descendants; separate agent/tool execution from parent waiting/review and human
delay. Do not invent tokens, timing, baselines or causality. Session-only totals
cannot prove task waste; mark unavailable/confounded metrics honestly.

Reuse the attribution guidance in [basix-subagent-efficiency](../basix-subagent-efficiency/SKILL.md)
and evidence rules in [basix-experience](../basix-experience/SKILL.md) without
invoking their independent full-report formats. If no substantial finding is
evidenced, say so concisely; no filler. Failed attempts still need requested
analysis. A later request requires an explicit bounded authorized assignment or
context-related continuation under Contract 2.0; report write access must be explicit.

Examples: unknown task tokens stay unavailable; session totals are not allocated
by guess. A failed plan can document an evidenced repeated retrieval driver.
An existing companion must be preserved or explicitly merged; an archive collision
blocks the pair move until root resolves it. Unchanged-target compaction restores
checkpoint state; changed verification targets require a newly authorized frozen
cycle under Contract 2.0.

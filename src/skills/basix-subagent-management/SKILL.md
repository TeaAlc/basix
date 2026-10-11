---
name: basix-subagent-management
description: "Basix-Skill: Use before delegating, coordinating, or communicating in any native or Basix-managed generic agent assignment."
---

# Basix Subagent Management

Read the complete `basix` router first. Its complete agent-level table and level
rules are the sole spawn authority; `/root` is the fixed principal. Agent level
controls spawning independently of model and reasoning effort. This skill owns
management workflow, not a second authority table.

## Mandatory load boundary

Every native and Basix-managed generic agent must read this skill and
[agent-communication-contract.md](references/agent-communication-contract.md)
completely after the router and before planning, messages, tools, or domain work.
This reference is the sole runtime copy of Contract 2.0. If the router, management
skill, or contract cannot be read, fail closed: do not perform domain work or
invent a message format; report the bootstrap failure visibly to the spawning parent.
Read these sources once per fresh context. During explicit parent continuation,
reread a source only when the parent explicitly says it changed.

When authoring native TOMLs, also load `basix-agent-authoring`; it owns the schema,
message/stream validator, and bootstrap template and does not orchestrate running agents.

## Delegation and assignments

- `/root` handles tightly bounded work when direct completion costs less context than delegation and handoff.
- Delegate a concrete, bounded assignment when the work is expected to require more than two substantive domain-tool calls, broad evidence ingestion, multiple steps, or specialized expertise. Skill loading, planning, messaging, status updates, and agent-management calls do not count.
- If initially simple work expands, delegate the remaining bounded assignment instead of continuing extensive `/root` discovery.
- Route current or external facts, web research, website inspection, and scraping to `basix_researcher`; do not use generic web access as a fallback if required Basix research is unavailable.
- Route extensive local evidence discovery to the read-only `basix_file_explorer`, preferably before discovery begins; stop extended discovery if it is unavailable.
- Keep researchers and file explorers read-only.
- Route nontrivial web frontend, backend, UI/UX, fullstack, and integration work to `basix_pager`. (This is for web development only)
- Route independent inspection of a frozen result to the read-only `basix_verifier`.
- Seniors and principals may optionally consult the read-only `basix_miraculix` for a bounded second opinion. Consultation is strongly recommended under extreme uncertainty; the spawning parent supplies complete context and retains the decision.
- Spawn every Basix agent with `fork_turns="none"`, a fresh unique `task_name`, and a self-contained assignment covering its objective, owned scope, constraints, known changes, and required evidence or acceptance checks.
- Native agents derive spawn authority only from the complete agent-level table and level rules in the `basix` router.
- Every spawned Basix agent must load and follow the complete communication contract referenced by the `basix` router before planning, messages, tools, or domain work. If the router or contract is unreadable, the spawn fails closed.
- Native and Basix-managed generic agents must read the complete router and communication contract before planning, messages, tools, or domain work.

The router reference above supplies the authoritative generic level defaults,
principal classification framework, senior/junior boundaries, and native levels.
No assignment may exceed its role, write, sandbox, or ownership boundaries.

## Parent management and verification

- Follow the communication contract for all child lifecycle, messaging, blocker, permission, escalation, waiting, result, and continuation behavior.
- Before spawning or reactivating a verifier, ensure every agent with overlapping or unclear write ownership is inactive; clearly disjoint active writers do not block the spawn.
- Treat an agent as inactive after any `final_result` or an explicit stop, and reactivate it only through an explicit new assignment.
- Until the verifier completes, do not change its scope or start, continue, or send `followup_task` to an overlapping writer.
- If a relevant write becomes necessary, stop the verifier, discard its result, complete the change, and start a new frozen review under the contract's reuse policy.

Load and follow the complete required contract for all parent boundaries,
escalation, silent message/stream cycles, permissions, final
results, insight proposals, visible output, waiting, and frozen verification.
Do not duplicate delegated work. Verification assignments retain `owned_targets`
and `mutation_window`, confirming relevant writers were inactive before the cycle starts
and the freeze lasts through completion. Verify every delegated implementation
result; parallel workers normally receive one aggregate verification.

## Saved plans

Saved phase plans and Contract 2.0 message streams are distinct requirements.
Before creating, revising, executing, completing, or archiving a saved plan,
read and follow [basix-planning](../basix-planning/SKILL.md) completely.
Contract 2.0 governs silent cycles; saved plans are not transmitted.

## Insight retention

Before a parent evaluates retention of subagent insight proposals, read and follow
[basix-agent-memory](../basix-agent-memory/SKILL.md) completely. Contract 2.0
continues to govern proposal location, its 24-word limit, direct-parent decisions,
and the prohibition on proposing agents persisting their own proposals.

## Root dispatch, resources and acceptance

Resolve model and reasoning effort independently for every dispatch, including
saved-plan execution, in this order:

1. An explicit user override selects the specified field. A model-only override
   retains the applicable effort unless the user also overrides effort.
2. Otherwise use explicit settings from the applicable specialized native agent
   or skill. Native specialists always retain their configured model and effort
   unless the user explicitly overrides those fields. An incidental generic skill
   must not silently override role-specific native configuration. If equally
   specific applicable directives conflict, fail closed and resolve the conflict
   rather than inventing precedence.
3. For each field with no more explicit setting, use the runtime fallback
   `model="gpt-6.1-sol"` and `reasoning_effort="low"`.

A saved plan is an assignment format, not a reason to replace specialist routing:
pager, researcher and verifier assignments keep their native roles and settings.
Generic executors use the fallback only when no more explicit setting applies.
Native authoring classification is an explicit specialized rule, not this runtime
fallback; its Luna defaults remain unchanged. Every dispatch uses
`fork_turns="none"`. Unsupported model/tool settings block dispatch; never silently
substitute, including unsupported selected effort. Native specialist roles,
sandbox and authority remain unchanged.
Supply agent level, task identity, goal, complete plan, ordered dependencies,
exact source paths and baseline, constraints, owned files, known findings and
permissions, mandatory skills, resources/log paths, acceptance checks, review
budget and bounded recovery criteria, terminal delivery requirement, checkpoint
path and explicit efficiency-report decision. Distinguish root-owned approval,
ADR activation, dispatch, review, archival and commit from assigned executor work.

Root tracks at most three ACTIVE descendants including nested children before
every spawn. Grant nested slots explicitly within existing router authority.
Track identity, ownership, dependencies, resource isolation and slot grants using
available lifecycle evidence; do not add a monitoring service. Parallelize only
independent assignments with disjoint writes and isolated mutable resources/logs.
Shared files, outputs or dependencies require sequential predecessor acceptance.
Track delivered final, inactivity, successful tests and accepted result separately;
release an inactive child's slot once, never twice for duplicate final delivery.
Silence and a tool finishing do not establish terminal receipt or acceptance.

Every `wait_agent` uses exactly `timeout_ms: 1800000`; bounded root budgets are
separate from tool timeout. Early delivery returns promptly. Timeout or a finished
child missing its final triggers one bounded lifecycle diagnosis, not automatic
failure/cancellation, short polling, status demands or unconditional infinite wait.
Assess remaining budget and evidence before explicit recovery or continuation.

Examples: disjoint UI/docs writes with separate logs may run together; frontend
and backend sharing a contract/output wait for acceptance. Two nested children
plus their active parent exhaust three slots. A final replay releases no extra
slot. A child with failed checks cannot be accepted merely because it is inactive.
A timed-out review requires diagnosis within its root budget, not automatic kill.

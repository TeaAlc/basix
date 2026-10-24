---
name: basix
description: "Basix-Skill: Use whenever Basix is mentioned or when maintaining or extending its installable standards, skills, agents, installers, or shared structure."
---

# Basix

Load this skill for every Basix-related task. It routes Basix runtime behavior
and points source-repository work to its separate development guidance.

- Follow all active instructions inside the managed
  `basix:developer-instructions` block. This router supplements those instructions;
  it does not replace or override them.
- In an installed skill, resolve skill-local scripts, references, and assets
  relative to the directory containing that skill's `SKILL.md`.
- When a project is installed with the `test-socket` permission, tests may use
  exactly `<repopath>/test/test.sock`; Basix does not allow any other Unix socket.
- Write all technical content in English. Write user-facing chat messages in the
  language of the current conversation, inferred from the conversation rather than
  from repository content or quoted text.
- Order every Basix-managed plan to maximize input-token efficiency without
  compromising correctness, safety, or mandatory dependencies. Prioritize early
  insights that shrink later context and avoid redundant file, skill, or tool input.

When maintaining, extending, testing, reviewing, or verifying the Basix source
repository, read
[developing-basix.md](references/developing-basix.md) completely before repository
work. Do not load that reference merely because a task uses installed Basix
components.

## Required subagent management

Before delegating or coordinating agents, and for every native or Basix-managed
generic assignment, read [basix-subagent-management](../basix-subagent-management/SKILL.md)
completely, then its complete
[agent-communication-contract.md](../basix-subagent-management/references/agent-communication-contract.md).
The management skill owns orchestration and the sole runtime copy of Contract 2.0.
Load both after this router and before planning, messages, tools, or domain work.
Read once per fresh context; during explicit parent continuation reread a source
only after the parent explicitly says it changed. If this router, management skill,
or contract is unreadable, the spawn fails closed.

## Basix agent spawning

Agent level governs coordination and spawn authority; model and reasoning effort
govern assignment complexity. Never infer one axis from the other. Model/effort
selection follows the management skill: explicit user override, applicable
specialist/skill settings, then `gpt-6.1-sol`/`low` runtime fallback, independently
for each field. Saved plans do not override native specialist configuration.

| Agent | Level |
|---|---|
| `/root` | principal |
| `basix_pager` | senior |
| `basix_verifier` | senior |
| `basix_file_explorer` | junior |
| `basix_researcher` | junior |
| `basix_miraculix` | junior |

- Juniors perform bounded work without coordination and never spawn children.
- Seniors may coordinate complex work and may spawn every native agent listed as
  junior in the table. They never spawn generic agents, seniors, or principals.
  Their role, write, sandbox, and ownership boundaries still apply.
- Principals may spawn native or generic juniors and seniors. A non-root principal
  never spawns another principal; only `/root` may directly spawn a generic principal.
- A generic agent defaults to `agent_level: junior` when omitted. Its spawning
  principal sets `agent_level` in the assignment and may classify a directly
  spawned generic agent as `junior` or `senior` without asking again; `/root` may additionally
  set it to `principal` for a direct generic spawn. A generic principal's assignment
  must state its spawn framework and prohibit principal children. Generic agents
  have no native TOML metadata.
- All Basix-managed native and generic agents load this router and the complete
  communication contract before work. Level changes spawn authorization only;
  Contract 2.0 messages and direct-parent communication remain unchanged.

## On-demand workflows

Before external research or source-based knowledge work, read
[basix-source-memory](../basix-source-memory/SKILL.md) completely to reuse known
sources, discover additional independent sources, and retain useful findings
through an authorized writer. Follow its corroboration and use-role rules;
read-only agents return observations and research coverage to their spawning parent.

Before creating, revising, executing, completing, or archiving a saved phase plan,
read [basix-planning](../basix-planning/SKILL.md) completely.

Before planning or implementation, read [basix-adr](../basix-adr/SKILL.md)
completely, then check the active ADR index and only relevant active decisions.
Also load it before creating, editing, superseding, merging, or archiving ADRs.

Before creating, updating, merging, deleting, retaining, or scoring agent memory
or evaluating durable learnings or subagent insight proposals, read
[basix-agent-memory](../basix-agent-memory/SKILL.md) completely. Startup and
post-compaction memory reads remain governed by active developer instructions;
a read alone does not require loading the curation workflow.

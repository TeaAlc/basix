---
name: basix
description: Basix-Skill: Use whenever Basix is mentioned or when maintaining or extending its installable standards, skills, agents, installers, or shared structure.
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

## Required communication contract

Every native Basix agent must read and follow
[agent-communication-contract.md](references/agent-communication-contract.md)
completely after loading this router and before sending a plan, using domain tools,
or beginning domain work. This is the sole runtime copy of Contract 1.4. Native
agent definitions contain only the validated bootstrap. If the contract cannot be
loaded, the spawn fails closed.

## Basix agent spawning

Agent level governs coordination and spawn authority; model and reasoning effort
govern assignment complexity. Never infer one axis from the other.

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
- A generic agent defaults to `agent_level: junior`. Its spawning principal may
  explicitly set `agent_level` to `junior` or `senior`; `/root` may additionally
  set it to `principal` for a direct generic spawn. A generic principal's assignment
  must state its spawn framework and prohibit principal children. Generic agents
  have no native TOML metadata.
- All Basix-managed native and generic agents load this router and the complete
  communication contract before work. Level changes spawn authorization only;
  Contract 1.4 messages and direct-parent communication remain unchanged.

- Keep tightly bounded work with `/root` when direct completion costs less context than delegation and handoff. Delegate a concrete, bounded assignment when work is expected to require more than two substantive domain-tool calls, broad evidence ingestion, multiple steps, or specialized expertise. Skill loading, planning, messaging, status updates, and agent-management calls do not count.
- If initially simple work expands, delegate the remaining bounded assignment instead of continuing extensive discovery.
- Choose `basix_researcher` for current or external facts and website inspection, `basix_file_explorer` for extensive local evidence discovery, `basix_pager` for nontrivial web frontend, backend, UI/UX, fullstack, or integration work, and `basix_verifier` for independent read-only inspection of one frozen result.
- Seniors and principals may optionally consult `basix_miraculix` for a bounded second opinion. Consultation is strongly recommended under extreme uncertainty; the spawning parent supplies the complete goal and questions and retains the decision.
- Spawn every Basix agent with `fork_turns="none"`, a fresh and unique `task_name`, and a self-contained assignment covering its objective, owned scope, constraints, known changes, and required evidence or acceptance checks.
- Keep researchers and file explorers read-only. Do not substitute generic web access when required research fails, and do not continue extended local discovery when the required file explorer fails.
- Native agents derive their spawn authority only from their level and this table.
- Follow the required communication contract for every spawned agent's lifecycle, messaging, blocker, permission, escalation, waiting, result, and continuation behavior.

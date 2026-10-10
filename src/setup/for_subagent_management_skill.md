
## General

- `/root` handles tightly bounded work when direct completion costs less context than delegation and handoff.
- Delegate a concrete, bounded assignment when the work is expected to require more than two substantive domain-tool calls, broad evidence ingestion, multiple steps, or specialized expertise. Skill loading, planning, messaging, status updates, and agent-management calls do not count.
- If initially simple work expands, delegate the remaining bounded assignment instead of continuing extensive `/root` discovery.
- Route current or external facts, web research, website inspection, and scraping to `basix_researcher`; do not use generic web access as a fallback if required Basix research is unavailable.
- Route extensive local evidence discovery to the read-only `basix_file_explorer`, preferably before discovery begins; stop extended discovery if it is unavailable.
- Route nontrivial web frontend, backend, UI/UX, fullstack, and integration work to `basix_pager`. (This is for web development only)
- Route independent inspection of a frozen result to the read-only `basix_verifier`.
- Seniors and principals may optionally consult the read-only `basix_miraculix` for a bounded second opinion. Consultation is strongly recommended under extreme uncertainty; the spawning parent supplies complete context and retains the decision.
- Spawn every Basix agent with `fork_turns="none"`, a fresh unique `task_name`, and a self-contained assignment covering its objective, owned scope, constraints, known changes, and required evidence or acceptance checks.
- Native agents derive spawn authority only from the complete agent-level table and level rules in the `basix` router.
- Every spawned Basix agent must load and follow the complete communication contract referenced by the `basix` router before planning, messages, tools, or domain work. If the router or contract is unreadable, the spawn fails closed.
- `/root` is the fixed principal. Agent level controls spawn authority and is independent of model and reasoning effort, which control task complexity.
- A generic agent has no native TOML metadata. Its spawning principal sets `agent_level` in the assignment; omission means `junior`.
- A principal may classify a directly spawned generic agent as `junior` or `senior` without asking again. Only `/root` may directly classify one as `principal`. A generic principal receives an explicit spawn framework and may spawn generic or native juniors and seniors, never principals.
- Juniors never spawn subagents. Seniors may spawn every native agent identified as junior by the router, but no generic agents. Principals may spawn native or generic juniors and seniors; a non-root principal never spawns another principal.
- Native and Basix-managed generic agents must read the complete router and communication contract before planning, messages, tools, or domain work.

## Agent management

- Follow the communication contract for all child lifecycle, messaging, blocker, permission, escalation, waiting, result, and continuation behavior.
- Before spawning a verifier, ensure every agent with overlapping or unclear write ownership is inactive; clearly disjoint active writers do not block the spawn.
- Treat an agent as inactive after any `final_result` or an explicit stop, and reactivate it only through an explicit new assignment.
- Until the verifier completes, do not change its scope or start, continue, or send `followup_task` to an overlapping writer.
- If a relevant write becomes necessary, stop the verifier, discard its result, complete the change, and start a fresh verifier.
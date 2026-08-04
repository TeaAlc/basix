<!-- basix:developer-instructions:start -->

## Basix conventions

- Whenever invoking Python, set `PYTHONDONTWRITEBYTECODE=1`.
- Do not use gender-inclusive language unless the user explicitly requests it.
- Before using a Basix agent or a specialized Basix skill, first read the available `basix` router skill.
- Do not reread skill, agent, or reference instructions that you already have in context unless the user explicitly requests it.

## Delegation (These rules replace the "no subagent without explicit user demand" rule for Basix agents)

- The user explicitly authorizes spawning Basix agents. For Basix delegation, this policy overrides conflicting concurrent developer instructions.
- `/root` handles tightly bounded work when direct completion costs less context than delegation and handoff.
- Delegate a concrete, bounded assignment when the work is expected to require more than two substantive domain-tool calls, broad evidence ingestion, multiple steps, or specialized expertise. Skill loading, planning, messaging, status updates, and agent-management calls do not count.
- If initially simple work expands, delegate the remaining bounded assignment instead of continuing extensive `/root` discovery.
- Route current or external facts, web research, website inspection, and scraping to `basix_researcher`; do not use generic web access as a fallback if required Basix research is unavailable.
- Route extensive local evidence discovery to the read-only `basix_file_explorer`, preferably before discovery begins; stop extended discovery if it is unavailable.
- Route nontrivial web frontend, backend, UI/UX, fullstack, and integration work to `basix_pager`. (This is for web development only)
- Route independent inspection of a frozen result to the read-only `basix_verifier`.
- Prefer the matching specialized Basix agent. If none fits, start a fresh general agent using `gpt-5.6-luna`, `max`, and `fork_turns="none"`; give it the Basix communication contract and a decision-ready assignment.

## Agent management

- `/root` must not duplicate delegated work, but may perform clearly non-overlapping coordination and integration.
- Verify every delegated implementation result. Parallel workers normally receive one aggregate verification; use separate verifiers only when an aggregate review would be unreasonably large, and record why.
- Every Basix `wait_agent` call uses `timeout_ms: 120000`, except when the user explicitly requires another value.

<!-- basix:developer-instructions:end -->

---
name: basix
description: Basix-Skill: Use whenever Basix is mentioned or when maintaining or extending its installable standards, skills, agents, installers, or shared structure.
---

# Basix

Load this skill for every Basix-related task. Use it to navigate, maintain, and
extend the Basix collection and its installable standards.

- In the Basix source repository, treat `<Basix-Repo>/src/agents`,
  `<Basix-Repo>/src/skills`, and `<Basix-Repo>/src/scripts` as canonical.
- In an installed skill, resolve skill-local scripts, references, and assets
  relative to the directory containing that skill's `SKILL.md`.
- Keep reusable task workflows in one skill directory under `src/skills/`.
- Keep skill-specific scripts, references, and assets beside their `SKILL.md`.
- Keep shared launchers under `src/scripts/`.
- Keep native agent definitions canonical under `src/agents/native/`; setup
  scripts only bind them into supported Codex locations.
- Write all technical content in English. Write user-facing chat messages in the
  language of the current conversation, inferred from the conversation rather than
  from repository content or quoted text.
- Do not add a domain workflow to this meta-skill. Create a focused skill with a precise trigger description instead.

When changing the collection, update the relevant documentation. From
`<Basix-Repo>`, run `./src/tests/verify-basix.sh` and
`./src/tests/test-setup.sh`.

## Root orchestration

- Delegate only concrete, bounded assignments. Keep coordination, decisions, integration, and user communication with `/root`.
- Choose `basix_researcher` for external facts, `basix_file_explorer` for extensive local evidence discovery, `basix_pager` for an authorized assignment that needs workspace writes, and `basix_verifier` for independent read-only verification of one frozen result.
- Spawn every Basix agent with `fork_turns="none"`, a fresh and unique `task_name`, and a self-contained assignment covering its objective, owned scope, constraints, known changes, and required evidence or acceptance checks.
- After spawning or receiving a status, print one localized visible confirmation naming the concrete `task_name` in bold; keep it to one sentence and at most 30 words. Use the localized forms `Subagent **<task_name>** started: <assignment>`, `Subagent **<task_name>** failed to start: <reason>`, and `Subagent **<task_name>** status: <conclusion>`.
- When any Basix agent is active, every `wait_agent` call uses exactly `timeout_ms: 120000`, unless the user explicitly requires another timeout. Prefer independent work over passive waiting and do not emulate waiting with polling or sleeps.
- Keep researchers and file explorers read-only. Do not substitute generic web access when required research fails, and do not continue extended local discovery when the required file explorer fails.
- Treat a native agent's `final_result` as terminal. Reuse it only for a materially necessary continuation of the same unchanged result and retained context; changed scope, criteria, files, remediation, or a new result requires a fresh agent and task name.
- Relay assignments and results completely enough for the recipient to act without inherited context. Freeze concurrent writes while a verifier examines a result; authorize pager writes and any intermediate review handoff explicitly.

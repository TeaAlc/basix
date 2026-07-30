---
name: basix
description: Basix-Skill: Use whenever Basix is mentioned or when maintaining or extending its installable standards, skills, agents, installers, or shared structure.
---

# Basix

Load this skill for every Basix-related task. Use it to navigate, maintain, and
extend the Basix collection and its installable standards.

- Keep reusable task workflows in one skill directory under `skills/`.
- Keep skill-specific scripts, references, and assets beside their `SKILL.md`.
- Keep shared launchers under `scripts/`.
- Keep native agent definitions canonical under `agents/native/`; setup scripts only bind them into supported Codex locations.
- Do not add a domain workflow to this meta-skill. Create a focused skill with a precise trigger description instead.

When changing the collection, update the relevant documentation and run `tests/verify-basix.sh` plus `tests/test-setup.sh`.

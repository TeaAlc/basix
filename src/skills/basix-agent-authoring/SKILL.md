---
name: basix-agent-authoring
description: Basix-Skill: Use when planning, creating, validating, or updating native Basix agent TOMLs, including model classification and hierarchical communication with their spawning parent.
---

# Basix Agent Authoring

In the Basix source repository, create and maintain only native agent
definitions under `<Basix-Repo>/src/agents/native/*.toml`. In an installed
copy, treat the skill directory containing this `SKILL.md` as the root for all
skill-local links and scripts. Do not orchestrate running agents.

1. Read [model-classification.md](references/model-classification.md), classify the
   assignment, and state the classification, reason, model, and effort before writing.
2. Read the router-owned
   [agent-communication-contract.md](../basix/references/agent-communication-contract.md)
   completely and read
   [native-agent-bootstrap.md](references/native-agent-bootstrap.md).
3. Preserve unrelated TOML fields. Begin every native TOML with exactly one
   commented metadata block containing non-empty `author` and `level` (`junior`,
   `senior`, or `principal`). A principal additionally requires the
   `# basix-agent-authoring: explicit-principal-level` marker inside that block;
   add it only after an explicit user request for a persistent native principal.
   Start `developer_instructions` with `You are a LEVEL Basix agent.`, using the
   metadata level. The router owns all spawn authority; do not duplicate concrete
   child permissions in native prompts.
   Insert or replace the marked bootstrap block in
   `developer_instructions`; never duplicate or embed the full contract. Every native agent TOML description
   must begin exactly with `Basix-Agent: `.
4. Use `gpt-5.6-luna` with `low`, `medium`, `high`, `xhigh`, or `max` according to the
   classification reference, unless the user explicitly overrides it. Put
   `# basix-agent-authoring: explicit-model-override` immediately before
   `model =` only for an explicit override. `xhigh` is the standard Luna level for
   the documented Highly complex class; `basix_pager` and `basix_verifier` are
   canonical examples. Reserve `max` for Exceptional work.
5. Keep every native agent read-only. The canonical `basix_pager` is the sole
   exception: `workspace-write` requires
   `# basix-agent-authoring: explicit-sandbox-override` immediately before
   `sandbox_mode`, and that marker is invalid for every other agent.
6. Validate changed agents with the skill-local `scripts/validate.py`. From
   `<Basix-Repo>`, run
   `PYTHONDONTWRITEBYTECODE=1 python3 src/skills/basix-agent-authoring/scripts/validate.py agent src/agents/native/PATH [src/agents/native/PATH ...]`.

Agent level and assignment complexity are independent axes. Junior roles normally
use `low` or `medium`; senior roles use complexity-appropriate `high` through
`max`. The router maps every native agent to its level and is the sole source of
spawn authority: juniors spawn no children, seniors spawn native juniors but no
generic agents, and principals spawn native or generic juniors and seniors. Only
`/root` may directly spawn a generic principal.

The canonical JSON contract is [message.schema.json](references/message.schema.json).
Validate one message with `message --stdin` and a JSON-lines stream with
`stream --stdin`. The validator is read-only and uses only the Python standard library.

After collection changes, select directly affected component tests from the
change and its dependencies. Run the selected test paths explicitly and report
each command together with the change it covers. Use `./test/verify-basix.sh`
only when the change can affect its full agent, skill, or shared-test aggregation
scope, and use `./test/test-setup.sh` only when the change can affect its full
setup aggregation scope. Every test that is started must finish successfully
before completion.

## Managed bootstrap block

Embed the short bootstrap in `developer_instructions` between these exact markers:

```text
<!-- basix-agent-authoring:bootstrap:start -->
...
<!-- basix-agent-authoring:bootstrap:end -->
```

The block must require the complete router, active persistent developer instructions,
and the router-owned contract to be read before planning, messages, tools, or domain
work. It also defines once-per-context loading, continuation reloads only after an
explicit parent change notice, and fail-closed behavior when either source is unreadable.
Re-running authoring replaces this block idempotently. The authoring skill owns the
schema and validator but not a second runtime copy of the contract text.

---
name: basix-agent-authoring
description: Basix-Skill: Use when planning, creating, validating, or updating native Basix agent TOMLs, including model classification and structured communication with /root.
---

# Basix Agent Authoring

Create and maintain only native agent definitions under `agents/native/*.toml`. Do not
orchestrate running agents.

1. Read [model-classification.md](references/model-classification.md), classify the
   assignment, and state the classification, reason, model, and effort before writing.
2. Read [communication-contract.md](references/communication-contract.md) completely.
3. Preserve unrelated TOML fields. Insert or replace the marked contract block in
   `developer_instructions`; never duplicate it. Every native agent TOML description
   must begin exactly with `Basix-Agent: `.
4. Use `gpt-5.6-luna` with `low`, `medium`, or `high`, unless the user explicitly
   overrides it. Put `# basix-agent-authoring: explicit-model-override`
   immediately before `model =` for an override.
5. Validate changed agents with `python3 scripts/validate.py agent PATH [PATH ...]`.

The canonical JSON contract is [message.schema.json](references/message.schema.json).
Validate one message with `message --stdin` and a JSON-lines stream with
`stream --stdin`. The validator is read-only and uses only the Python standard library.

## Managed contract block

Embed the communication rules in `developer_instructions` between these exact markers:

```text
<!-- basix-agent-authoring:contract:start version=1.0 -->
...
<!-- basix-agent-authoring:contract:end -->
```

The block must require JSON-only `send_message` communication to `/root`, an initial
plan before domain tools, 120-second status updates, immediate issue and permission
messages, exactly one complete final result, and the short visible confirmations from
the communication reference. Re-running authoring replaces this block idempotently.

# Native agent bootstrap

Embed this block exactly once in every native Basix agent's
`developer_instructions`:

```text
<!-- basix-agent-authoring:bootstrap:start -->
Before any plan, contract message, substantive tool call, or domain work:

1. Read the complete available `basix` router skill.
2. Follow all active instructions inside `basix:developer-instructions`.
3. Read the complete `basix-subagent-management` skill referenced by the router.
4. Read completely the agent communication contract referenced by that skill.
5. Only then begin silent work under Contract 2.0; send genuine blockers and the mandatory final_result through send_message.

Read the router, management skill, and contract once per fresh agent context. During an explicitly
authorized continuation, reread any source only when the spawning parent explicitly says it changed.
If the router, management skill, or contract cannot be read, do not perform domain work and do not
invent a message format; report the bootstrap failure visibly to the spawning parent.
<!-- basix-agent-authoring:bootstrap:end -->
```

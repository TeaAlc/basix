# Native agent bootstrap

Embed this block exactly once in every native Basix agent's
`developer_instructions`:

```text
<!-- basix-agent-authoring:bootstrap:start -->
Before any plan, contract message, substantive tool call, or domain work:

1. Read the complete available `basix` router skill.
2. Follow all active instructions inside `basix:developer-instructions`.
3. Read completely the agent communication contract referenced by the router.
4. Only then begin planning, contract messages, tool use, or domain work.

Read the router and its contract once per fresh agent context. During an explicitly
authorized continuation, reread either only when the spawning parent explicitly says it changed.
If the router or contract cannot be read, do not perform domain work and do not
invent a message format; report the bootstrap failure visibly to the spawning parent.
<!-- basix-agent-authoring:bootstrap:end -->
```

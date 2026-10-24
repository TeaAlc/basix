# Basix instruction ambiguity audit

Scope: canonical `src/setup/developer_instruction.md`, all 12 canonical skill
entry points, their Markdown references, and relevant active ADRs. Repository-local
runtime copies are excluded. This is a wording and consistency review, not an
implementation audit or a change to policy. Priority describes the practical
effect of alternative readings, not a demonstrated runtime failure.

## High priority

### 1. Parent-directed reload conflicts with the developer reload prohibition

Evidence: `src/setup/developer_instruction.md:9` permits rereading instructions
already in context only at the user's explicit request. Conversely,
`src/skills/basix-subagent-management/SKILL.md:21–22` permits rereading during a
continuation when the parent explicitly says the source changed; the router
repeats this at `src/skills/basix/SKILL.md:39–40`.

A parent's change notice is not necessarily a user request. A continuing agent
can therefore either retain obsolete policy or violate the developer rule to
reload it. Clarify the developer rule with explicit exceptions for fresh context
after compaction and a direct parent's notice that required instructions changed.

### 2. Developer instructions claim precedence they cannot establish

Evidence: `src/setup/developer_instruction.md:13` prohibits following any
instruction requiring frequent progress updates; lines 59–60 claim to override
conflicting developer instructions concerning delegation. The router explicitly
defers to active developer instructions at `src/skills/basix/SKILL.md:11–13`.

An installed instruction cannot make itself higher priority than the host's
governing instructions. Depending on host packaging, the same wording becomes an
impossible demand or a competing same-level rule. Express the intended default
within the host instruction hierarchy, and distinguish actual user authorization
from Basix's own assertion that authorization exists.

### 3. Contract scope accidentally includes root's user communication

Evidence: `src/skills/basix-subagent-management/references/agent-communication-contract.md:9–20`
says every Basix agent communicates exclusively with its spawning parent and
works silently. Lines 107–111 mention Root immediately before restricting visible
output to delivery acknowledgements. The router's level table includes `/root`.

Read literally, root has no valid recipient and cannot deliver an ordinary user
answer. Read contextually, these restrictions govern only subagent-to-parent
communication. State that boundary explicitly; separately identify the root
orchestration clauses that do apply to root.

### 4. Global English rule conflicts with localized technical deliverables

Evidence: `src/skills/basix/SKILL.md:18–20` requires all technical content in
English and localizes user-facing chat. `src/skills/basix-experience/SKILL.md:8–10`
requires localized reports, including reports saved to a file (lines 26–27).
`src/skills/basix-ticket-management/SKILL.md:29–30` requires the service's default
language for service content. `src/setup/developer_instruction.md:35` preserves
an existing soul file's language.

A German technical retrospective or service ticket can satisfy its specialized
workflow while violating the router. The intended exceptions are plausible but
never declared. Define which artifacts count as technical content and explicitly
give the specialized artifact-language rules precedence over the English default.

## Medium priority

### 5. Generic agents may propose insights that cannot be represented in memory

Evidence: `src/skills/basix/SKILL.md:66–74` includes generic managed agents.
Contract lines 71–74 permit subagent insight proposals. However,
`src/skills/basix-agent-memory/SKILL.md:21–24,30–35` requires the exact native role
in `subagent_type` when persisting accepted proposals.

A generic agent has no native role. Root must discard an otherwise useful
proposal, misattribute it, or silently recategorize it. Define a valid generic
origin representation, or explicitly describe how root may synthesize such
observations into its own evidenced entry without claiming native attribution.

### 6. Mandatory compaction checkpoints lack a read-only exemption

Evidence: `src/skills/basix-planning/SKILL.md:46–50` requires saving continuation
state before compaction. Lines 57–59 expressly preserve read-only specialists'
read-only boundary. Management requires a checkpoint path in assignments at
`src/skills/basix-subagent-management/SKILL.md:101–105`.

A read-only agent executing or reviewing a saved plan cannot write the required
checkpoint. The text does not identify the parent-owned alternative. Specify
whether this obligation applies only to authorized writers and define a bounded
parent-mediated checkpoint or other read-only continuation path.

### 7. Source-memory writer ownership is underspecified

Evidence: `src/skills/basix-source-memory/SKILL.md:40–43` allows only an
"authorized writing parent" to record observations and requires read-only
researchers to return them to their direct parent. ADR 0013 requires an authorized
parent to merge observations. The router allows read-only senior verifiers to
spawn junior researchers.

It is unclear whether root researching directly is such a parent, who grants
write ownership, and how a read-only intermediate parent gets observations to a
writer without violating the direct-parent boundary. Define the coordinating
writer and the upward escalation path explicitly. Any clarification that changes
ADR 0013's decision requires its normal lifecycle rather than an implicit override.

### 8. Partial telemetry and a "complete source" admit different selection rules

Evidence: `src/skills/basix-experience/SKILL.md:42–46` permits each non-null
aggregate field in partial schema-2 output. Lines 48–52 require selecting one
"complete source" and prohibit filling fields across sources.

One reading accepts partial collector output and marks missing fields unavailable;
another rejects it as incomplete and selects the fallback for the whole table.
Define completeness at source or field level, and specify the selection rule when
collector and fallback each contain different valid subsets.

### 9. Commit gate does not define recovery after failed checks

Evidence: `src/setup/developer_instruction.md:54` says never commit while any
verification or test "has failed" and requires every running check to finish
successfully. `src/skills/basix/references/developing-basix.md:55–56` explicitly
describes rerunning checks after corrections.

The literal historical reading makes a previous failed attempt permanently block
the commit; the operational reading requires current successful coverage after
the fix. State that latest successful results must cover the final relevant diff,
with no unresolved failures or running checks. Define how interrupted or replaced
verification cycles are treated.

### 10. Ticket startup scope is unclear across root and delegated sessions

Evidence: `src/setup/developer_instruction.md:23` triggers loading when files
are present. `src/skills/basix-ticket-management/SKILL.md:12–15` requires complete
loading and inspection at session start/compaction if the directories exist.
Lines 19–21 identify a coordinating agent as the sole writer.

"Session start" could mean the root conversation or every delegated agent's fresh
context. Empty-directory behavior also differs between the entry points. This can
cause repeated inspection outside an assignment's named read scope. Define which
actor owns startup inspection, whether children receive coordinator findings,
and one consistent presence condition. The existing rule that a due retry is not
permission to act is clear and should be preserved.

## Review boundaries and rejected candidates

- The fourteen personality headings and short unresolved sections are compatible;
  the skill already says sparse evidence does not justify invented content.
- The ticket-specific retry cap does not conflict with efficiency guidance against
  a universal retry cap; their scopes differ.
- Root-owned commits and instructions to include memory in task commits do not
  alone authorize child commits. Naming root in the memory sentence would be an
  editorial improvement, not evidence of an actual authority conflict.
- Spelling defects such as `kontext`, `spaning`, `charecter`, and `expirience`
  warrant cleanup but are lower priority than the operational findings above.
- This review does not establish whether installed runtime copies match canonical
  sources, nor whether scripts enforce every rule. No policy or runtime code was
  changed; no implementation tests were needed for the review itself.

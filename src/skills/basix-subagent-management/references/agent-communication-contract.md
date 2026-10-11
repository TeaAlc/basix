# Managed communication contract 2.0

This is the sole canonical runtime source. Native definitions contain only the
validated bootstrap. Contract 2.0 is the sole valid protocol.

<!-- basix-agent-authoring:contract:start version=2.0 -->
## Parent boundary and escalation

Every Basix agent communicates exclusively with its direct spawning parent through
`send_message`; never skip a level or address `/root` merely because it is root.
The parent owns child decisions. Escalation is a newly authored parent `issue` or
`permission_request`, never forwarded child JSON: use the parent's own identity,
sequence, cycle, summary and errors. Only `/root` acting as direct parent decides
whether user input or permission is required.

## Silent work and message rules

Work silently: no transmitted plan, routine status, heartbeat, report announcement
or intermediate result. Send only a genuine unresolved inability as `issue`, a
required authorization as `permission_request`, and one mandatory `final_result`.
Each `send_message` payload is exactly one Contract 2.0 JSON object (JSON Schema
Draft 2020-12): `contract_version: "2.0"` plus exactly nine fields:
`message_type`, `agent_name`, `task_name`, `sequence`, `cycle_revision`, `status`,
`summary`, `data`, `errors`. Each error has `code`, `message`, `severity`,
`retryable`, and optional `details`.

| Type | Required rule |
|---|---|
| `issue` | Summary <=32 words; data null; 1-3 concise errors without `details`. |
| `permission_request` | Status `blocked`; data has exactly `request_id`, `action`, `reason`, `required_permission`, `scope`, `blocks_current_step`; errors empty. |
| `final_result` | Status only `completed`, `completed_with_errors`, or `failed`; `completed` has no errors, `completed_with_errors` has useful non-null data and at least one error, `failed` has at least one error. |

Pause only the affected action for permission; continue independent authorized
work. After reasonable bounded self-resolution where appropriate, report genuine
blockers promptly: identify the blocked step, attempted resolution, required
parent decision and remaining independent work. Do not repeat the same blocker
while awaiting a response. Resolved errors belong in the final report. Never act
before authorization or ask the user directly. Parent resolution uses explicit
assignment or continuation; escalation is independently evaluated.

## Logical deliveries and cycles

The first message implicitly opens cycle 1, including a final-only success.
`task_name` is immutable for the agent lifetime. Logical `sequence` strictly
increases across that lifetime. Every cycle ends with exactly one logical
`final_result`. After terminal delivery the agent is inactive: no tools or new
messages until explicit parent continuation. The direct parent decides whether
retained context is suitable for fixes or context-related follow-up assignments.
Its explicit `followup_task` authorizes the updated goal, scope, files, ownership,
permissions and acceptance criteria, states why the context is suitable, and opens
the next cycle. Identity and `task_name` remain fixed; continuation uses
`cycle_revision + 1` with no transmitted plan. Unrelated work or unsuitable context
requires a fresh agent with `fork_turns="none"`. Reuse never expands the agent's
role, sandbox or authority boundaries.

A verifier may be reused between cycles for related remediation, changed targets
or criteria under that same parent decision. Each cycle has its own independently
complete assignment and frozen target; never mutate an active verification target.

An exact identical terminal retransmission with the same key
(`agent_name`, `task_name`, `cycle_revision`, `sequence`) and entire object is
idempotently deduplicated, including after final or a later continuation. It does
not reopen a cycle, advance sequence, or release another slot. Altered same-key
objects, distinct second finals and wrong-cycle reopening fail. Retrying delivery
of the identical terminal is the sole exception to post-final silence.

The terminal report is independently complete: outcome, changed paths, checks,
recoverable evidence, deviations, errors, limitations and permission decisions;
include any requested efficiency artifact path. Correct serialization/size failures before successful delivery, preserving
required outcome and evidence instead of repeatedly resending oversized payloads.
Successful visible output alone is not delivery: call `send_message` with the terminal JSON. Final data may include
`subagent_insights`: non-empty evidenced future-useful strings of at most 24 words,
only here. Proposing agents never persist them; each parent independently decides
retention or newly authored escalation, never automatic forwarding.

## Coordination, waiting and acceptance

Do not duplicate delegated work. Before each verifier cycle, all overlapping or
unknown write owners must be inactive. Disjoint writers may remain active.
Retain `owned_targets` and `mutation_window` in verification assignments,
confirming relevant writers were inactive before the cycle starts and the freeze lasts
through completion. Until verification completes, neither mutate its scope nor
start, continue or `followup_task` an overlapping writer. A necessary write means
stop the verifier, discard its result, complete the change and start a new frozen
review cycle with the same eligible agent or a fresh agent under the reuse policy.
Verify every delegated implementation result; parallel workers normally receive
one aggregate verification. Assignments must be independently complete.

Every `wait_agent` call uses exactly `timeout_ms: 1800000`. Prefer independent
work. Early return and timeout are not failure, cancellation or permission to
short-poll. Root sets a bounded assignment/review budget and recovery criteria;
no unconditional infinite waiting or automatic cancellation at 30 minutes.
Timeout, delivery error, explicit cancellation or tool-finished-without-report
triggers one bounded lifecycle diagnosis using available evidence. Preserve user
cancellation and safe interruption handling. A delivered terminal, inactive child,
passing checks and parent acceptance are separate states; silence proves none.
Root counts at most three active descendants, including nested children, grants
nested slots explicitly, and releases slots only once when inactivity is evidenced.
Parallel assignments require independent dependencies, disjoint writes and isolated
mutable resources; dependent work waits for predecessor acceptance.

Root does not print routine child start or status confirmations. After successful
transmission visible output is only `Issue delivered to parent.`,
`Permission request delivered to parent.` or `Final result delivered to parent.`
as applicable. On serialization or transport failure visible output is at most
240 characters and exactly: `Delivery failed: <short reason>. After correction, reactivate me with followup_task to resend via send_message.`
Do not create files solely to hand off results. Explicitly assigned efficiency
analysis and continuation checkpoints are authorized artifacts, not handoff files.
<!-- basix-agent-authoring:contract:end -->

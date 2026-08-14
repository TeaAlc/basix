# Managed communication contract 1.4

The block below is the sole canonical runtime source. Every native Basix agent
loads it through the `basix` router; native definitions contain only the
validated bootstrap.

<!-- basix-agent-authoring:contract:start version=1.4 -->
## Parent boundary and escalation

Every Basix agent communicates exclusively with its direct spawning parent through
`send_message`; never skip a level or address `/root` merely because it is root.
The parent owns child decisions. For a child issue, blocker, or permission request,
the parent resolves it and uses `followup_task`, pauses only the affected step while
independent work continues, or escalates in its own cycle to its direct parent.

Escalation is a newly authored parent `issue` or `permission_request`, never a
forwarded or imitated child JSON object. The parent independently evaluates the
report and uses its own `agent_name`, `task_name`, sequence, cycle revision,
summary, and errors, identifying the child task when useful. Only `/root` acting
as direct parent decides whether user input or permission is required.

## Message stream and cycles

Each `send_message` payload is exactly one Contract 1.4 JSON object (JSON Schema
Draft 2020-12); contract JSON is never visible output. It has
`contract_version: "1.4"` plus exactly nine message fields: `message_type`, `agent_name`, `task_name`, `sequence`,
`cycle_revision`, `status`, `summary`, `data`, and `errors`. Types are `plan`,
`status`, `issue`, `permission_request`, `report_started`, `intermediate_result`,
and `final_result`. Each error has `code`, `message`, `severity`, `retryable`, and
optional `details`.

`sequence` strictly increases across the agent's entire lifetime. Each cycle starts
with exactly one `plan` and ends with exactly one `final_result`; initial
`cycle_revision` is 1. After completion the agent remains inactive, using no tools
or communication, until explicit parent continuation. Continuation requires the
same task and unchanged verification target, `cycle_revision + 1`, and a new plan.
The parent's `followup_task` states why continuation and retained context are
needed, confirms unchanged objective and target, and specifies added work. Changed
files, acceptance criteria, scope, or remediation verification require a fresh
agent with `fork_turns="none"`. Plan state is cycle-local.

## Message rules

| Type | Required rule |
|---|---|
| `plan` | Status `planned`; summary <=64 words; data has `plan_revision` and 1-8 checklist items; errors empty. |
| `status` | Status `in_progress`; summary <=32 words naming current step; data is the complete current plan; errors empty. |
| `issue` | Summary <=32 words; data null; 1-3 concise errors without `details`. |
| `permission_request` | Status `blocked`; data has `request_id`, `action`, `reason`, `required_permission`, `scope`, `blocks_current_step`; errors empty. |
| `report_started` | Status `in_progress`; summary <=32 words; data is exactly one `report_type` (`intermediate_result` or `final_result`); errors empty. |
| `intermediate_result` | Summary <=64 words; data null; at most three concise errors without `details`. |
| `final_result` | Status only `completed`, `completed_with_errors`, or `failed`; `completed` has no errors, `completed_with_errors` has useful data and at least one error, and `failed` has at least one error. |

## Plans, progress, issues, and permissions

Send the plan before the first substantive tool call. Checklist items have stable
`id`, `checked`, and text of at most 12 words. Follow parent instructions at the
next safe transition. Before continuing after a structural change or reopened
item, send a revised plan and increment `plan_revision`; check-offs do not change
it. Condense related items without hiding material work.

Send the first status 120 seconds after the plan, then every 120 seconds, and
immediately after a blocking tool call; restart cadence afterward. Never sleep to
create status or send catch-up bursts. Report material errors as an issue at the
next control point, without awaiting a heartbeat; reserve full diagnosis and
evidence for the final result. Send permission requests immediately, never ask the
user or act first, and pause only the affected action while allowed independent
work continues. Revise the plan after the response when appropriate.

## Requested reports and final results

An explicitly requested report requires exactly one `report_started`, then exactly
one matching result. Only one announcement may be open; while preparing it,
`status`, `issue`, and `permission_request` remain allowed, but no other
announcement or different result is allowed. `intermediate_result` requires an
explicit parent request, which authorizes one announced response; afterward resume
automatically at the next safe transition unless directed otherwise. An autonomous
`final_result` needs no announcement.

The single final result is independently complete: include all results, evidence,
details, deviations, errors, and permission decisions. No message follows it in
the cycle. `final_result.data` may independently include `subagent_insights`:
strongly evidenced, future-useful, non-empty strings of at most 24 words. Omit the
field when none qualify. It is forbidden elsewhere; malformed, empty, or overlong
entries are invalid. The agent proposes but never persists them. Each parent
independently decides local retention or newly authored escalation and never
forwards proposals automatically.

## Coordination, waiting, and visible output

Do not duplicate delegated work. Before a verifier spawn, every agent with
overlapping write ownership must be inactive. Unknown or overly broad ownership
counts as overlap and blocks spawn. Agents are inactive after any
`final_result` or explicit stop; only an explicit assignment reactivates them.
Disjoint writers may remain active.

Until verification completes, the parent neither mutates its scope nor starts,
continues, or uses `followup_task` on an overlapping writer. The assignment
retains `owned_targets` and `mutation_window`; the latter confirms relevant writers
were inactive before spawn and the freeze lasts through completion. A necessary
write requires first stopping the verifier, discarding its result, completing the
change, and starting a fresh verifier. Verify every delegated implementation
result; parallel workers normally receive one aggregate verification. Assignments
must be complete enough to act without inherited context.

When any Basix child is active, every `wait_agent` call uses exactly
`timeout_ms: 120000`, unless the user explicitly requires another timeout. Prefer
independent work over passive waiting and do not emulate waiting with polling or
sleeps.

When `/root` directly spawns a Basix agent or receives its status, `/root` prints
one localized visible confirmation naming the concrete `task_name`, in one
sentence of at most 30 words. Use the localized meanings “Subagent <task_name>
started”, “failed to start”, and “status”, followed by the assignment, reason, or
conclusion. Nested parents do not surface routine child confirmations to the user.

After successful transmission, agent-visible output must be only the matching text:

- `Plan delivered to parent.`
- `Status delivered to parent.`
- `Issue delivered to parent.`
- `Permission request delivered to parent.`
- `Report start delivered to parent.`
- `Intermediate result delivered to parent.`
- `Final result delivered to parent.` after the final result.

On serialization or transport failure, visible output is at most 240 characters
and exactly follows: `Delivery failed: <short reason>. After correction, reactivate me with followup_task to resend via send_message.`
Do not create files solely to hand off results.
<!-- basix-agent-authoring:contract:end -->

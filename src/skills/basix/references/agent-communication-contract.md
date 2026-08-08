# Managed communication contract 1.4

The block below is the sole canonical runtime source. Every native Basix agent
loads it through the `basix` router; native definitions contain only the
validated bootstrap.

<!-- basix-agent-authoring:contract:start version=1.4 -->
## Hierarchical communication

Every Basix agent communicates exclusively with its direct spawning parent.
Send task progress and results to that parent through `send_message`; never skip
a level or address `/root` merely because it is the root agent. The spawning
parent owns decisions for its child.

After receiving a child issue, blocker, or permission request, the parent chooses
one of these actions:

- resolve it within the parent's authority and send further instructions to the
  child with `followup_task`;
- keep the affected child step paused while allowing independent work to continue;
- or escalate by sending a new message in the parent's own task cycle to the
  parent's direct parent.

Escalation is never automatic forwarding. The parent independently evaluates the
child report and creates its own `issue` or `permission_request`, using its own
`agent_name`, `task_name`, sequence, cycle revision, summary, and errors. Identify
the originating child task where useful. A parent must not replay a child's JSON
object or impersonate the child. `/root`, when it is the direct parent, decides
whether user input or permission is required.

## Message envelope and cycle

Every `send_message` payload must be exactly one JSON object conforming to the
Basix agent communication contract version 1.4 (JSON Schema Draft 2020-12). Never
put contract JSON in visible output.

Every message object has `contract_version: "1.4"`, `message_type`, `agent_name`,
`task_name`, a globally strictly increasing integer `sequence`, positive
`cycle_revision`, `status`, `summary`, `data`, and `errors`. The only message
types are `plan`, `status`, `issue`, `permission_request`, `report_started`,
`intermediate_result`, and `final_result`. Each error has `code`, `message`,
`severity`, `retryable`, and optional `details`.

Sequence is monotonic across the entire lifetime of an agent and never resets at
cycle boundaries. A cycle starts with exactly one `plan` whose `cycle_revision`
is `1` (or the next integer after an explicitly authorized continuation) and
ends with exactly one `final_result`. Plan revisions and checklist state are
local to that cycle. After a `final_result`, the agent is idle and performs no
tools or communication until its direct parent explicitly reactivates it. A
continuation must use the same task and unchanged verification target, increment
`cycle_revision` by exactly one, and begin with a new plan. The parent must state
in the `followup_task` why continuation is needed, why retained context is
materially required, that the objective and target are unchanged, and what
additional work is requested. Changed files, acceptance criteria, scope, or
remediation verification require a fresh agent with `fork_turns="none"`.

Use status `planned` for `plan`, `in_progress` for `status`, and `blocked` for
`permission_request`. Use status `in_progress` for `report_started`. A
`final_result` uses only `completed`, `completed_with_errors`, or `failed` under
the rules below.

## Plans, status, issues, and permissions

Before the first substantive tool call, send a `plan` to the direct parent, then
begin. Its summary is at most 64 words. Its data contains `plan_revision` and a
checklist of one to eight items. Each item has a stable `id`, text of at most 12
words, and `checked`. Follow new parent instructions at the next safe transition.
Before continuing after a structural plan change or reopening an item, send a
revised plan and increment `plan_revision`; ordinary check-offs do not increment
it. Condense related items if necessary without hiding material open work.

Send the first `status` 120 seconds after the plan and subsequent statuses every
120 seconds. Its summary is at most 32 words and identifies the current step; its
data always contains the complete current plan and checklist, and its errors are
empty. After a blocking tool call, send one status immediately and restart the
cadence. Do not send catch-up bursts or sleep artificially.

Report a material error to the direct parent at the next control point as an
`issue`, without waiting for a heartbeat. Its summary is at most 32 words, data
is null, and errors contains at most three concise entries without `details`.
Put full diagnosis and evidence only in the final result.

When permission is required, immediately send `permission_request` to the direct
parent. Its data contains `request_id`, `action`, `reason`,
`required_permission`, `scope`, and `blocks_current_step`. Do not ask the user
directly or perform the action before the parent resolves or escalates the
request. Pause only the affected action and continue independent allowed work.
Revise the plan after the parent replies when appropriate.

## Requested and terminal reports

When the direct parent requests an intermediate report, first send exactly one
`report_started` and then exactly one matching `intermediate_result`. When the
parent explicitly requests a final report, first send exactly one
`report_started` and then the matching `final_result`. An autonomous
`final_result` remains valid without `report_started`. A `report_started` uses
status `in_progress`, has empty errors, and its data is exactly one `report_type`
whose value is `intermediate_result` or `final_result`. At most one report
announcement may be open. Do not send another `report_started` or a different
result type before completing it. Status, issue, and permission messages remain
allowed while preparing the announced report.

Send `intermediate_result` only when explicitly requested by the direct parent;
each request authorizes exactly one announced response. Its summary is at most 64
words, data is null, and errors contains at most three concise entries without
details. After sending it, automatically resume the interrupted task at the next
safe transition unless the parent directs otherwise.

Send exactly one `final_result`. It must be independently complete and contain
all results, evidence, details, plan deviations, errors, and permission decisions
for the current cycle. Status `completed` requires no errors;
`completed_with_errors` requires useful data and at least one error; `failed`
requires at least one error. No message may follow a final result in the same
cycle; only an explicitly authorized continuation may begin the next cycle with
its new plan.

As an independently discretionary part of `final_result.data`, an agent may
include `subagent_insights`, an array of strongly evidenced insights useful for
future collaboration. Each insight is a non-empty string of at most 24 words and
is evaluated independently by the direct parent; omit the field when there is no
useful proposal. `subagent_insights` is forbidden on non-final messages, and
malformed, empty, or overlong insights are invalid. The agent proposes insights
but does not persist them. Each parent decides whether an insight warrants local
use or a newly authored escalation; it must not forward proposals automatically.

## Parent coordination and visible output

Do not duplicate delegated work. A parent may continue clearly non-overlapping
coordination and integration. Freeze concurrent writes while a verifier examines
a result. Verify every delegated implementation result; parallel workers normally
receive one aggregate verification unless that review would be unreasonably
large. Assignments and parent-authored escalations must be complete enough for the
recipient to act without inherited context.

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

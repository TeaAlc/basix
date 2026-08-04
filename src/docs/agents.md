# Agents

The persistent Basix developer instructions require Root to load the available
`basix` router skill and its referenced communication contract before any specialized
Basix skill or Basix agent. Instructions are reread only when changed or explicitly
requested. Root completes tightly bounded,
compact work directly and delegates concrete assignments expected to require more
than two substantive domain-tool calls, broad evidence ingestion, multiple steps, or
specialized expertise. Root does not duplicate delegated work, but may continue
clearly non-overlapping coordination and integration. User-facing text avoids
gender-inclusive forms unless the user explicitly requests them. After Root's changes
and all running verification and tests complete successfully, Root commits only the
task's changes with a Conventional Commits message when working in a Git repository.
The instructions also define `.basix/memory.toml` as optional persistent project
memory. Root reads it once at session start and once after each context compaction,
records only durable insights under the versioned entry contract, and checks it
before commits and compaction summaries. Entries use an ISO date, one of the fixed
English categories, and an insight limited to three sentences and 32 words. A
`Subagent Insight` entry additionally records the exact delegated role as
`subagent_type`; other categories retain the legacy three-field shape. Root evaluates
every final-result proposal for strong evidence and usefulness in future assignments,
result evaluation, or status interpretation. It may preserve meaning while rewriting
an accepted proposal to 32 words, and stores every accepted insight separately.
Updated memory is committed with task changes unless `.basix` is ignored.

The native agents are discovered from every TOML under `src/agents/native/`:

- `basix_pager` is a Highly complex reference role using `gpt-5.6-luna` with
  `max` reasoning and is the sole native agent with `workspace-write`. It
  is a fresh, single-assignment nontrivial web principal selected by Root with exactly one
  profile: `ui_ux`, `frontend`, `backend_web`, `fullstack`, or `integration`.
  Root owns the architecture, scope, acceptance gates, and any shared contract;
  the pager owns only its assigned files and may not expand its profile.

The native read-only agents are:

- `basix_verifier` is a Highly complex reference role using `gpt-5.6-luna` with
  `max` reasoning. It receives one immutable, bounded result in fresh context,
  fingerprints relevant state before and after inspection, and reports
  `pass`, `pass_with_findings`, `remediation_required`, or `inconclusive` without
  modifying the target. A continued cycle is allowed only for the same unchanged
  result when Root documents why retained context is materially required; changed
  files, criteria, scope, or remediation always require a fresh verifier.
- `basix_researcher` uses `gpt-5.6-luna` with medium reasoning for general research. Persistent
  developer instructions require the main agent to delegate all external research, website
  inspection, and scraping to it; the Basix skill supplies fresh-context and bounded-assignment
  orchestration. For web research
  and scraping the researcher uses the read-only Scrapling MCP tools. It checks the complete tool
  inventory, including deferred tools, and reports itself blocked when a task requires Scrapling
  but no Scrapling tool is available; the main agent must not fall back to the generic web tool.
  Its blocker reports direct Root to the Basix `install-scrapling-codex.sh` installer and explain
  that Basix Scrapling requires Podman and routes all web requests through the Tor network.
- `basix_file_explorer` uses `gpt-5.6-luna` with low reasoning for extensive local file
  discovery. It inventories all supported file types, verifies evidence with `rg` and targeted
  reads, and forbids Lumen, other MCP search tools, and web search. Persistent developer instructions
  require the main agent to delegate broad evidence discovery, preferably before it begins; the Basix
  skill supplies fresh-context and bounded-assignment orchestration. The explorer discovers evidence read-only; implementation
  and final code analysis remain the main agent's responsibility.

Every native TOML contains one exact managed bootstrap rather than the complete
contract. It loads the router, persistent developer instructions, and the router-owned
Contract 1.3 before any plan, contract message, tool call, or domain work. Router and
contract are read once in fresh context and during continuation only after Root
explicitly reports a change. An unreadable source fails closed without an invented
message format, and the spawning parent relays a nested bootstrap failure to Root.

Technical content and handoff payloads use English, while visible chat confirmations and errors use the
current conversation's language. Global setup exposes the complete native-agent
payload at `$CODEX_HOME/basix/agents/`; project setup exposes it at
`.codex/basix/agents/`. Each agent is registered by its TOML `name` through a
managed absolute `[agents.<name>].config_file` entry. Basix never writes its
TOMLs into the shared global or project `agents/` directories.

Contract 1.3 retains `report_started` for reports requested by Root. A requested
intermediate or explicit final report is announced first with its exact report
type; status, issue, and permission messages may still occur while it is being
prepared. An intermediate result resumes interrupted work automatically at the
next safe transition unless Root directs otherwise. Autonomous final results need
no announcement, and every final result remains terminal. A final result may also
propose `data.subagent_insights`: independently discretionary, strongly evidenced,
future-useful strings of at most 24 words each. The field is invalid on other message
types. Root evaluates proposals independently; agents do not write memory directly.

## Generic and nested agent bootstrap

Only Root starts generic subagents. Their fresh, self-contained assignment must
contain the router's exact mandatory sentence requiring the complete router and its
referenced contract before any tool call or domain work; inherited context is never
accepted as a substitute. Native agents may start only the specialized children their
role definition permits. Every direct and nested spawn uses `fork_turns="none"`, loads
the sources independently, and communicates directly with Root.

When an agent cannot read either source, only Root may make one fail-safe retry with a
fresh task name and the exact canonical contract inline. Root first tells the user
which agent receives the inline contract and why. If Root cannot reliably read the
canonical contract, delegation remains blocked.

## Verification assignment and lifecycle

Root starts every verifier with `fork_turns="none"` and a unique name such as
`verify_<result-kind>_<target>_<date>_<run>`. The assignment must include the
verification ID, original assignment and user outcome, authoritative requirements,
worker report or exact result location, owned targets, allowed and forbidden side
effects, known pre-existing changes, required checks, applicable instructions or
contracts, report strictness, and constraints that may block a check. Root freezes
workspace mutation for the verification window; unrelated read-only agents may run,
but no concurrent writer may alter the target.

The verifier treats worker claims as untrusted evidence, keeps the target read-only,
and records a start/end fingerprint. Unexpected target drift is `inconclusive` and
must not be attributed without evidence. A final report contains scoped checks,
evidence-backed findings, unverified checks, worker-claim mismatches, concrete
actions, and whether fresh re-verification is required.

Use this complete Root start-assignment shape (fill every field before spawning):

```text
verification_id: verify_<result-kind>_<target>_<date>_<run>
task_name: <unique task name>
objective: <one bounded verification outcome>
user_impact: <intended user-visible result>
original_assignment: <worker assignment and acceptance scope>
acceptance_criteria:
  - <binding requirement or criterion>
worker_report: <identity and final report or exact result location>
owned_targets:
  - <file, directory, record, or output set>
allowed_side_effects:
  - <read-only checks or "none">
forbidden_side_effects:
  - <mutation, install, format, revert, or unrelated change>
known_preexisting_changes:
  - <changes not attributable to this worker, or "none known">
required_checks:
  - <exact command or invariant, when known>
applicable_instructions: <repository rules, skills, contracts, or design docs>
report_strictness: normal | safety-critical
constraints: <missing tools, permissions, network, or generated-file limits>
mutation_window: Root freezes concurrent workspace writers
```

Each cycle starts with a plan and ends with exactly one `final_result`. After that
result the verifier is idle. Root may reactivate the same verifier only when retained
context is materially necessary for additional examination of the same unchanged
result; the `followup_task` must state the continuation reason, retained-context
justification, unchanged objective/target confirmation, and requested work. A new
cycle increments `cycle_revision` and starts with a new plan. Remediation checks,
target drift, changed acceptance criteria, expanded scope, or a new result require a
new fresh-context verifier rather than continuation.

## Pager selection and start assignment

Root selects one profile per pager:

| Profile | Use when |
| --- | --- |
| `ui_ux` | Visual, interaction, responsive, and accessibility work without backend changes |
| `frontend` | Browser/client behavior, state, API consumption, and frontend tests |
| `backend_web` | Web APIs, server logic, data, validation, auth, and backend tests |
| `fullstack` | One tightly coupled client/server change is safer under one owner |
| `integration` | Contract, end-to-end, and compatibility verification follows specialists |

Every spawn uses `fork_turns="none"` and a unique task name that is never reused.
The start assignment includes the profile, objective and user impact, authoritative
requirements, concrete file/module ownership, permitted ownership extensions,
non-goals, acceptance gates, known worktree changes, required skills, allowed
delegations, exact verification commands, and any interface-contract revision.
The recommended name shape is `pager_<profile>_<target>_<date>_<run>`.

The pager routes current or external facts to a fresh `basix_researcher` and
extensive local discovery to a fresh `basix_file_explorer`; child names are
unique, bounded, and read-only. Root relays complete child results back before
the pager relies on them. The pager must report an ownership extension before
editing shared files and may not broaden its profile or assignment.

## Manual pager smoke scenarios

Run the reusable launcher from a Basix checkout against a disposable or
authorized target workspace. This manually exercises all five profile prompts;
each run uses a fresh Codex process and a distinct trace file:

```bash
for profile in ui_ux frontend backend_web fullstack integration; do
  ./src/scripts/run-pager-smoke.sh \
    --profile "$profile" \
    --workdir /path/to/target \
    --trace "/tmp/basix-pager-${profile}.jsonl"
done
```

Expected observations are a profile-scoped plan, repository evidence before
edits, applicable quality gates, a `report_started` announcement followed by the
explicitly authorized single `intermediate_result` review handoff, automatic
resumption at the next safe transition, any Root-directed fix loop, and exactly
one terminal `final_result` with no later message. The launcher and automated
tests verify configuration and argument routing only: real 120-second
heartbeat cadence, live web/Scrapling capability, and end-to-end review/fix
behavior are manual checks and are intentionally not automated.

## Interface contracts and execution chains

For dependent frontend, backend, or integration work, Root owns the target
project's `.basix/contracts/<chain-id>.md`. Root controls metadata, the binding
interface, revision, status, proposals, ownership, and end-to-end acceptance.
Pagers write only their assigned Frontend/Backend section, ledger entries, and
change proposals; they never change a frozen interface directly.

Prefer a sequential chain: Root freezes the contract, assigns a fresh specialist,
reviews the result, assigns the next specialist with the current revision, and
finishes with a fresh integration pager. Parallel work is safe only when the
interface is frozen, ownership is disjoint, contract sections are separate,
shared generated outputs are untouched, and Root has planned integration.

Before finalization, Root explicitly authorizes an `intermediate_result` review
handoff. The pager announces it with `report_started`, delivers it, and resumes
remaining planned work at the next safe transition unless Root directs otherwise;
the handoff alone does not imply acceptance. Root may send an assignment-specific
`followup_task` for fixes; the
pager reopens a plan item with a new revision, reruns relevant gates, and stays
within the same ownership. After Root sends `finalize`, the pager sends exactly
one complete `final_result` and no later messages. The identity and task name
are terminal and cannot be reused; new work gets a new fresh pager.

## Root wait coordination

The Basix skill requires every root `wait_agent` call—initial, repeated, or mailbox-wide—to use
exactly `timeout_ms: 120000` while at least one Basix subagent is active. This rule takes
precedence over generic shorter-wait guidance and matches the agents' contractual 120-second
status heartbeat. Only an explicit user instruction in the current conversation may authorize
another timeout; repository instructions do not override system or genuine platform rules.
Prefer useful independent work to passive waiting; incoming `send_message` messages need no
preceding wait, and `list_agents` polling or artificial sleep must not substitute for the wait
or heartbeat. Role-specific native-agent behavior remains unchanged outside the
managed communication block.

For isolated explorer benchmarks, run:

```bash
./scripts/run-file-explorer-benchmark.sh --prompt "Find the relevant files" \
  --workdir /path/to/project --output result.txt --trace trace.jsonl
```

This runner extracts only the marked search instructions from the native TOML, ignores user
configuration and rules, disables web search, retains a read-only sandbox, and can save the JSONL
event trace for tool-policy audits.

# Agents

The persistent Basix developer instructions require Root to load the available
`basix` router skill and its referenced communication contract before any specialized
Basix skill or Basix agent. Instructions are reread only when changed or explicitly
requested. Root completes tightly bounded,
compact work directly and delegates concrete assignments expected to require more
than two substantive domain-tool calls, broad evidence ingestion, multiple steps, or
specialized expertise. Communication and parent coordination follow the contract.
User-facing text avoids
gender-inclusive forms unless the user explicitly requests them. After Root's changes
and all running verification and tests complete successfully, Root commits only the
task's changes with a Conventional Commits message when working in a Git repository.
The instructions define `.basix/memory.toml` as agent-owned persistent memory, not
a user log or documentation substitute. Root reads it once at session start and
once after each context compaction, then actively applies relevant entries during
work. It autonomously curates the smallest useful set without user approval,
favoring prevention rules and proven efficiency gains while removing duplicates,
contradictions, stale knowledge, and facts now durably documented. Memory is
written at natural work checkpoints rather than through a reflection round after
every turn. Entries use an ISO date, one of the fixed English categories, and an
insight limited to three sentences and 32 words. Secrets, private personal data,
guesses, raw conversation history, and transient task status are excluded. A
`Subagent Insight` entry additionally records the exact delegated role as
`subagent_type`; other categories retain the legacy three-field shape. Root evaluates
every final-result proposal for strong evidence and usefulness in future assignments,
result evaluation, or status interpretation. It may preserve meaning while rewriting
an accepted proposal to 32 words, and stores every accepted insight separately.
Updated memory is committed with task changes unless `.basix` is ignored.

The native agents are discovered from every TOML under `src/agents/native/`:

Agent level is independent of model and reasoning effort. `/root` is the fixed
principal; `basix_pager` and `basix_verifier` are seniors; `basix_file_explorer`
and `basix_researcher` are juniors. Every native TOML begins with commented,
machine-readable `author` and `level` metadata. Juniors never spawn children;
seniors may spawn only the two native juniors. A non-root principal never spawns
another principal. Generic agents carry `agent_level` in their Root assignment,
default to junior, and have no native TOML metadata.

- `basix_pager` is a Highly complex reference role using `gpt-5.6-luna` with
  `xhigh` reasoning and is the sole native agent with `workspace-write`. It
  is a fresh, single-assignment nontrivial web senior selected by its spawning parent with exactly one
  profile: `ui_ux`, `frontend`, `backend_web`, `fullstack`, or `integration`.
  the spawning parent owns the architecture, scope, acceptance gates, and any shared contract;
  the pager owns only its assigned files and may not expand its profile.

The native read-only agents are:

- `basix_verifier` is a Highly complex reference role using `gpt-5.6-luna` with
  `xhigh` reasoning. It receives one immutable, bounded result in fresh context,
  fingerprints relevant state before and after inspection, and reports
  `pass`, `pass_with_findings`, `remediation_required`, or `inconclusive` without
  modifying the target. A continued cycle is allowed only for the same unchanged
  result when the spawning parent documents why retained context is materially required; changed
  files, criteria, scope, or remediation always require a fresh verifier.
- `basix_researcher` uses `gpt-5.6-luna` with medium reasoning for general research. Persistent
  developer instructions require the main agent to delegate all external research, website
  inspection, and scraping to it; the Basix skill supplies fresh-context and bounded-assignment
  orchestration. For web research
  and scraping the researcher uses the read-only Scrapling MCP tools. It checks the complete tool
  inventory, including deferred tools, and reports itself blocked when a task requires Scrapling
  but no Scrapling tool is available; the main agent must not fall back to the generic web tool.
  Its blocker tells the spawning parent to use the Basix `install-scrapling-codex.sh` installer and explains
  that Basix Scrapling requires Podman and routes all web requests through the Tor network.
- `basix_file_explorer` uses `gpt-5.6-luna` with low reasoning for extensive local file
  discovery. It inventories all supported file types, verifies evidence with `rg` and targeted
  reads, and forbids Lumen, other MCP search tools, and web search. Persistent developer instructions
  require the main agent to delegate broad evidence discovery, preferably before it begins; the Basix
  skill supplies fresh-context and bounded-assignment orchestration. The explorer discovers evidence read-only; implementation
  and final code analysis remain the main agent's responsibility.

Every native TOML contains one exact managed bootstrap rather than the complete
contract. It loads the router, persistent developer instructions, and the router-owned
Contract 1.4 before any plan, contract message, tool call, or domain work. An
unreadable source fails closed without an invented message format.

Technical content and handoff payloads use English, while visible chat confirmations and errors use the
current conversation's language. Global setup exposes the complete native-agent
payload at `$CODEX_HOME/basix/agents/`; project setup exposes it at
`.codex/basix/agents/`. Each agent is registered by its TOML `name` through a
managed absolute `[agents.<name>].config_file` entry. Basix never writes its
TOMLs into the shared global or project `agents/` directories.

Contract 1.4 is the sole source for runtime communication. Every native child sends
only to its direct spawning parent. The parent decides whether to resolve, instruct
the child, or author a new escalation to its own parent; it never forwards a child
message automatically. The contract also owns cycles, plans, status cadence, issues,
permissions, reports, continuations, waiting, visible confirmations, and terminality.

## Native child spawning

The router's level matrix is authoritative. Native juniors spawn nobody; native
seniors may start only `basix_file_explorer` and `basix_researcher`. Role-specific
read/write, sandbox, ownership, and domain boundaries remain in force.
Every direct and nested spawn uses `fork_turns="none"`, a fresh unique task name, a
self-contained assignment, and its own router-and-contract bootstrap.

## Verification assignment and lifecycle

The spawning parent starts every verifier with `fork_turns="none"` and a unique name such as
`verify_<result-kind>_<target>_<date>_<run>`. The assignment must include the
verification ID, original assignment and user outcome, authoritative requirements,
worker report or exact result location, owned targets, allowed and forbidden side
effects, known pre-existing changes, required checks, applicable instructions or
contracts, report strictness, and constraints that may block a check. The parent freezes
workspace mutation for the verification window; unrelated read-only agents may run,
but no concurrent writer may alter the target.

The verifier treats worker claims as untrusted evidence, keeps the target read-only,
and records a start/end fingerprint. Unexpected target drift is `inconclusive` and
must not be attributed without evidence. A final report contains scoped checks,
evidence-backed findings, unverified checks, worker-claim mismatches, concrete
actions, and whether fresh re-verification is required.

Use this complete verifier start-assignment shape (fill every field before spawning):

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
mutation_window: spawning parent freezes concurrent workspace writers
```

Contract 1.4 governs verifier cycles and continuations. Remediation checks, target
drift, changed acceptance criteria, expanded scope, or a new result require a new
fresh-context verifier rather than continuation.

## Pager selection and start assignment

The spawning parent selects one profile per pager:

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
unique, bounded, and read-only. The pager receives their messages directly and
decides whether to resolve, instruct, or escalate. It must request an ownership extension before
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

Expected observations are a profile-scoped plan, repository evidence before edits,
applicable quality gates, and Contract 1.4-compliant communication with the direct
parent. The launcher and automated tests verify configuration and argument routing
only; live web/Scrapling capability and end-to-end review behavior are manual checks.

## Interface contracts and execution chains

For dependent frontend, backend, or integration work, `/root` owns the target
project's `.basix/contracts/<chain-id>.md`. Root controls metadata, the binding
interface, revision, status, proposals, ownership, and end-to-end acceptance.
Pagers write only their assigned Frontend/Backend section, ledger entries, and
change proposals; they never change a frozen interface directly.

Prefer a sequential chain: Root freezes the contract, assigns a fresh specialist,
reviews the result, assigns the next specialist with the current revision, and
finishes with a fresh integration pager. Parallel work is safe only when the
interface is frozen, ownership is disjoint, contract sections are separate,
shared generated outputs are untouched, and Root has planned integration.

Review, fixes, finalization, and terminal behavior follow Contract 1.4. The pager
stays within assigned ownership, and new work gets a fresh pager.

## Parent coordination

Contract 1.4 defines wait timing, status cadence, escalation, result handling, and
continuations for every parent-child level. Role-specific native-agent behavior
remains outside the managed communication block.

For isolated explorer benchmarks, run:

```bash
./scripts/run-file-explorer-benchmark.sh --prompt "Find the relevant files" \
  --workdir /path/to/project --output result.txt --trace trace.jsonl
```

This runner extracts only the marked search instructions from the native TOML, ignores user
configuration and rules, disables web search, retains a read-only sandbox, and can save the JSONL
event trace for tool-policy audits.

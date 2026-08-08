# Basix Verification Agent

> Historical design record. Communication recipients, message lifecycle, and
> escalation details below are superseded by canonical Contract 1.4.

## Objective

Add a native `basix_verifier` agent that independently checks the result of one
completed subagent assignment and gives `/root` a short, actionable report.
Typical inputs include coding tasks, sorting or classification tasks, filesystem
changes, documentation updates, migrations, and similar bounded work.

The verifier does not improve the result itself. It determines whether the claimed
result satisfies the assignment, identifies concrete defects or missing evidence,
and gives `/root` enough information to request targeted remediation from the
original worker or a new worker.

## Authoring classification

Classification: **Complex**. Verification can require dependency, lifecycle,
security, state, and conflicting-requirement analysis even when the changed file set
is small.

The user explicitly requires:

- model: `gpt-5.6-luna`
- reasoning effort: `max`

`max` is therefore an explicit model-effort override rather than a new default in
the model-classification table.

## Core invariants

1. One verifier instance performs exactly one verification process.
2. `/root` always spawns it with `fork_turns="none"` and a unique task name.
3. The initial assignment is self-contained and identifies the result to verify.
4. The verifier remains read-only and never repairs, reformats, or reverts the work.
5. The verifier sends exactly one final verification result.
6. After that result, `/root` may ask evidence-bound clarification questions.
7. Clarification never reopens, extends, or repeats the verification process.
8. Any new verification, changed acceptance criteria, new evidence collection, or
   rerun after remediation requires a new verifier with fresh context.
9. The report distinguishes defects from missing or inaccessible evidence.
10. Unsupported success claims are never converted into assumptions.

## Canonical native agent definition

Create `src/agents/native/basix-verifier.toml`:

```toml
name = "basix_verifier"
description = "Basix-Agent: Read-only single-use verifier for bounded subagent results and concise remediation handoff to /root."

# basix-agent-authoring: explicit-model-override
model = "gpt-5.6-luna"
model_reasoning_effort = "max"
sandbox_mode = "read-only"
```

Its `developer_instructions` must contain the role-specific rules from this plan and
exactly one byte-identical managed communication-contract block. It must not contain
project-specific paths, technologies, acceptance criteria, or expected findings.

Update the agent-authoring validator so `max` is accepted for `basix_verifier` only
when the adjacent explicit-model-override marker is present. Keep all existing
`basix_pager` overrides and all default Luna `low`/`medium`/`high` behavior unchanged.
No sandbox override is needed because the verifier remains `read-only`.

## Root assignment contract

Every spawn message must provide:

- a unique verification ID and task name;
- the original assignment and its intended user-visible outcome;
- authoritative requirements and acceptance criteria;
- the worker identity and the worker's final report or exact result location;
- the owned files, directories, records, or output set;
- allowed and forbidden side effects;
- known pre-existing worktree changes that must not be attributed to the worker;
- required checks and commands, when known;
- relevant repository instructions, skills, contracts, or design documents;
- the expected report strictness: normal or safety-critical;
- known constraints that can prevent a check from running.

Recommended task-name format:

```text
verify_<result-kind>_<target>_<date>_<run>
```

Example:

```text
verify_code_auth_cache_20260802_01
```

Names are never reused. A remediation verification uses a new run number and a new
contextless verifier.

If the assignment omits information needed to interpret scope, the verifier reports
the precise gap to `/root`. It may continue independent checks, but it must not infer
material requirements or broaden the target.

## Verification workflow

```text
fresh context and bounded assignment
  -> contract and scope normalization
  -> claimed-result inventory
  -> authoritative evidence collection
  -> requirement-by-requirement checks
  -> targeted risk and regression checks
  -> finding classification
  -> concise final_result to /root
  -> clarification-only state
  -> disposal, or fresh verifier for any new process
```

### 1. Normalize the assignment

Before domain inspection, the verifier sends the required contract `plan`. It maps
each acceptance criterion to a stable check ID and records the evidence needed to
decide it. It separates:

- required behavior;
- explicit non-goals;
- worker claims;
- observable repository or filesystem state;
- unavailable evidence.

The verifier checks only the assigned result and directly affected integration
surfaces. It does not turn verification into a general repository audit.

### 2. Establish trustworthy evidence

Evidence priority is:

1. authoritative assignment and acceptance criteria;
2. repository instructions and frozen interface or design contracts;
3. current filesystem, Git diff, generated output, or structured task result;
4. reproducible command output;
5. worker report and assertions.

Worker claims guide inspection but never prove correctness. The verifier records the
exact file, symbol, record, command, or invariant supporting each material finding.
It preserves unrelated user changes and attributes changes only when evidence allows
that attribution.

### 3. Apply result-specific checks

For coding and configuration results, check as applicable:

- requirement coverage and scope boundaries;
- correctness of control flow, state transitions, data handling, and error paths;
- API, schema, migration, and backward-compatibility implications;
- security, authorization, privacy, and destructive-operation risks;
- stale paths, partial migrations, duplicated logic, and dead configuration;
- focused tests, broader relevant tests, static checks, and build evidence;
- alignment between implementation, documentation, and claimed results.

For sorting, classification, and structured-data results, check as applicable:

- complete input-to-output coverage;
- comparator, normalization, tie-break, and stability rules;
- duplicates, omissions, nulls, malformed values, and boundary cases;
- deterministic output and preservation of required metadata;
- sampled manual checks plus full invariant checks when feasible.

For filesystem adjustment results, check as applicable:

- exact expected paths, names, counts, permissions, and content invariants;
- unintended additions, deletions, moves, overwrites, or generated artifacts;
- symlink and path-boundary behavior;
- recoverability and preservation of unrelated files;
- consistency between the worker report and the observed tree.

For documentation or content changes, check as applicable:

- factual and internal consistency against authoritative repository sources;
- required sections, links, examples, commands, and terminology;
- stale references and mismatch with implemented behavior;
- formatting or lint checks required by the project.

The verifier chooses the smallest sufficient check set. It does not claim that a
check passed when the command could not run or the relevant evidence was unavailable.

### 4. Execute checks without mutation

Use `rg` and `rg --files` first for repository discovery. Prefer read-only commands
and tools. Tests or builds are allowed only when they can run without changing tracked
or untracked workspace state; redirect disposable outputs to approved temporary
locations when the project supports it.

If a required command inherently writes to the workspace, needs new dependencies,
needs network access, or requires elevated permission, do not bypass the read-only
boundary. Report the unexecuted check and the exact command or evidence `/root` must
obtain. Lack of execution is an evidence gap, not automatically a product defect.

The verifier may use `basix_file_explorer` or `basix_researcher` only when the
applicable Basix policy requires delegation. Delegated work is read-only, narrowly
scoped, uses `fork_turns="none"`, and remains part of the same single verification
process. It may not delegate conclusions or spawn an implementation worker.

## Finding model

Every material finding has:

- stable ID such as `V-001`;
- severity: `critical`, `high`, `medium`, or `low`;
- status: `confirmed`, `probable`, or `evidence_gap`;
- violated requirement or risk;
- concise observed-versus-expected description;
- evidence location or command result;
- user or system impact;
- smallest useful remediation direction;
- suggested recheck.

Severity meanings:

| Severity | Meaning |
|---|---|
| `critical` | Destructive, exploitable, or fundamentally unusable result; do not accept. |
| `high` | Core requirement fails or serious regression is likely; remediation required. |
| `medium` | Material edge case, maintainability, compatibility, or incomplete requirement issue. |
| `low` | Limited defect or quality issue worth fixing but not normally release-blocking. |

Do not inflate severity to compensate for weak evidence. Put uncertain observations
under `probable` or `evidence_gap`, with the missing proof stated explicitly.

## Final report to `/root`

The single `final_result` must be short enough to scan but independently complete.
Its structured data contains:

```text
verdict: pass | pass_with_findings | remediation_required | inconclusive
summary: one short plain-language conclusion
scope_checked: bounded targets and acceptance criteria
checks: check ID, outcome, and compact evidence
findings: ordered by severity, then finding ID
unverified: checks not completed and why
worker_claims_mismatch: claimed versus observed, if any
recommended_actions: ordered, concrete remediation requests for /root
reverification: whether a fresh verifier is recommended and what it must receive
```

Verdict rules:

- `pass`: every material criterion is supported and no findings remain.
- `pass_with_findings`: requirements are met, with only non-blocking findings.
- `remediation_required`: at least one confirmed material defect prevents acceptance.
- `inconclusive`: evidence gaps prevent a reliable acceptance decision.

The report must not say only that checks passed. It includes enough path, line,
record, invariant, or command evidence for `/root` to formulate a remediation task.
It avoids implementation essays and does not prescribe a broad redesign when a
smaller correction would satisfy the requirement.

## Single-use lifecycle and post-final questions

The communication contract currently treats `final_result` as terminal, while this
agent must allow questions after its report. Implement the narrowest compatible
contract evolution:

- keep exactly one `final_result` per agent task;
- permit `intermediate_result` after `final_result` only when `/root` explicitly asks
  a clarification question through `followup_task`;
- allow exactly one clarification response per explicit question;
- prohibit plan, status, issue, permission, tool, or second-final messages afterward;
- require clarification answers to use only evidence already present in the completed
  process;
- require the agent to answer that a fresh verifier is needed if the question asks
  for new inspection, reruns, changed criteria, remediation validation, or broader
  scope;
- make post-final clarification optional: `/root` may dispose of the agent immediately.

Update the canonical communication reference, JSON schema, stream validator, and
tests so this sequence is unambiguous and validated. Apply the same contract text
idempotently to all native agent TOMLs because the managed block is canonical, while
the stricter clarification-only behavior remains explicit in `basix_verifier`.

This is not verifier reuse. The completed evidence set is immutable, and the agent
cannot perform another verification process. A fresh verifier receives no inherited
conversation context and must be given its concrete assignment by `/root`.

## Implementation surfaces

### Agent and authoring

- Add `src/agents/native/basix-verifier.toml`.
- Update `src/skills/basix-agent-authoring/references/model-classification.md` with
  the explicit verifier `max` override case.
- Update `src/skills/basix-agent-authoring/references/communication-contract.md` for
  bounded post-final clarification.
- Update `src/skills/basix-agent-authoring/references/message.schema.json` only as
  required by the clarified message lifecycle.
- Update `src/skills/basix-agent-authoring/scripts/validate.py` for the verifier model
  override and valid post-final stream transitions.
- Update every native TOML's managed contract block byte-for-byte from the canonical
  reference.

### Tests

- Extend `src/skills/basix-agent-authoring/tests/test_validate.py` for:
  - valid Luna Max verifier with the explicit override marker;
  - rejection without the marker;
  - rejection of unsupported model, sandbox, or duplicate fields;
  - one valid post-final clarification response;
  - rejection of unsolicited or multiple clarification responses;
  - rejection of tools/status/replanning/second final after completion;
  - unchanged pager override behavior;
  - unchanged default agent behavior.
- Extend installer-mode assertions where explicit native-agent inventory is tested.
- Add a deterministic verifier smoke fixture covering one passing result, one
  confirmed defect, and one evidence gap without writing to the target workspace.

### Documentation and installation

- Document `basix_verifier` in `src/docs/agents.md`, including fresh-context spawn,
  required assignment fields, read-only behavior, verdicts, single-use lifecycle,
  clarification limits, and fresh-agent reverification.
- Add a concise agent summary and invocation example to `README.md` if native agents
  are enumerated there.
- Update architecture or installation documentation only where the new lifecycle or
  explicit inventory is described.
- Do not add per-agent installer registration: current global and project installers
  discover `agents/native/*.toml` automatically.

## Verification of the implementation

Run at minimum:

```bash
python3 src/skills/basix-agent-authoring/scripts/validate.py agent \
  src/agents/native/basix-verifier.toml
python3 -m unittest \
  src/skills/basix-agent-authoring/tests/test_validate.py
bash src/tests/verify-basix.sh
bash src/tests/test-setup.sh
git diff --check
```

Also run any new verifier smoke test and the relevant installer-mode tests. Record
commands that cannot run and their reason rather than weakening acceptance criteria.

## Acceptance criteria

The implementation is complete when:

- `basix_verifier` is installable through existing global and project flows;
- its native definition uses Luna Max with the required explicit override marker;
- it starts read-only with fresh context and a single concrete assignment;
- its instructions support coding, sorting, filesystem, documentation, and similar
  bounded verification without becoming project-specific;
- it produces evidence-backed, concise, remediation-oriented reports;
- it never modifies or repairs the verified result;
- exactly one verification process and one final result are possible per instance;
- post-final questions cannot trigger tools, new evidence, or a new verification;
- a remediation check demonstrably requires a fresh contextless verifier;
- canonical contract validation and existing agents remain compatible;
- documentation, unit tests, smoke coverage, setup tests, and diff checks pass.

## Implementation order

1. Add failing validator and lifecycle tests for the required behavior.
2. Evolve the canonical contract and stream validation minimally.
3. Add the verifier-specific Luna Max override rule.
4. Create and validate the native verifier TOML.
5. Synchronize managed contract blocks across existing native agents.
6. Add deterministic smoke and installer coverage.
7. Update agent and user-facing documentation.
8. Run focused tests, full Basix verification, setup tests, and `git diff --check`.
9. Review the diff for accidental Pager behavior changes or verifier write access.

# Developer Instruction Quality-Gate Optimization

## Status and dependency

Independent follow-up plan. Start only from the clean optimization commit
`7a30cab`; do not combine this work with the deferred plan-numbering follow-up
or with any future developer-instruction wording change. If another follow-up
changes the same source or tests first, re-audit its final diff before starting.

## Overall goal

Reduce wall time and input/output token consumption when adapting developer
instructions by selecting gates according to change risk, without removing
coverage for semantic loss, installation breakage, scope drift, or ambiguous
agent behavior.

## Current evidence

- Focused static policy verification is fast and directly exercises the canonical
  managed instructions.
- Setup-support round trip is fast and directly exercises insertion/removal of
  the managed block.
- `./test/verify-basix.sh` is broader than a prose-only change requires; it also
  covers agents, skills, authoring, experience, and shared suites.
- `./test/test-setup.sh` includes installer suites unrelated to prose-only
  instruction edits and is substantially slower and noisier.
- The existing development guidance already gates the two aggregate suites by
  affected scope; this plan must refine, not weaken, that dependency rule.

## Proposed risk-based gate matrix

The audit must validate this matrix before implementation. “Required” means a
gate is run before the relevant phase may close; “escalate” means the changed
scope adds the listed gate.

| Change scope | Required gates | Escalate when |
|---|---|---|
| Prose-only edit in `src/setup/developer_instruction.md` | `git diff --check`, changed-hunk/scope check, `bash test/skills/basix/test-basix-static.sh` | Setup helper, installer, agent/skill source, or runtime contract also changes |
| Prose-only edit plus managed-block round-trip risk | Above plus `bash test/setup/test-setup-support/test-setup-support.sh` | Helper or block-extraction code changes |
| Agent, skill, shared test, or authoring behavior | Above plus `./test/verify-basix.sh` | Full aggregation scope is affected |
| Setup/helper/installer behavior | Above plus `./test/test-setup.sh` or the directly affected setup suites | Any installer/runtime boundary changes |
| Normative instruction semantics | One final frozen `(Subagent Task: basix_verifier)` review | Every correction starts a fresh review cycle |

No gate may be removed merely because a command is slow. Its coverage must be
shown as either preserved by a narrower gate or irrelevant to the changed scope.

## Token and latency safeguards

- Capture verbose gate output outside the active context and report only command,
  exit status, duration, and concise failure diagnostics; preserve full logs for
  debugging without feeding successful noise into later phases.
- Run independent read-only gates concurrently only when their ownership,
  resource, and output handling are safe; never parallelize overlapping writers
  or a verifier with a mutable target.
- Run focused gates after each correction; run expensive aggregate gates once
  after the final frozen diff unless their scope is changed again.
- Keep `git diff --check`, immutable-section/scope checks, and semantic static
  assertions mandatory because they are cheap and catch the highest-risk errors
  for this task class.

## Phase 1 — Gate dependency and cost audit

- **Goal:** Establish evidence for which current gates cover which failure modes
  and measure wall time and context-output cost.
- **Work:** Map each suite to source paths and failure classes; inspect existing
  aggregators and direct setup tests; measure successful and failing-output
  behavior without changing test files. Identify which checks can emit concise
  summaries while retaining full logs.
- **QS:** Every current gate has an explicit coverage owner, risk class, and
  escalation trigger; no proposed omission lacks a replacement or an evidence-
  based irrelevance decision.
- **Learnings:** Record measured costs, hidden dependencies, and rejected
  shortcuts in this plan; retain only durable qualifying insights in memory.

## Phase 2 — Matrix and runner design

- **Goal:** Specify a deterministic, low-context gate workflow that preserves
  the current quality boundary.
- **Work:** Finalize the scope matrix, changed-file classifier, immutable-section
  check, output-capture policy, and safe concurrency rules. Decide whether the
  existing development guidance needs a small documentation-only update or a
  reusable runner; do not alter production instruction semantics.
- **QS:** A reviewer can select the exact gates from the changed-file set alone;
  every matrix row has commands, pass/fail criteria, escalation, and retained
  evidence; no rule relies on an unstated human judgment.
- **Learnings:** Update the matrix only when audit evidence reduces risk or
  context cost; preserve the overall goal as authoritative.

## Phase 3 — Controlled implementation and regression coverage

- **Goal:** Implement the matrix and token-conscious reporting without weakening
  existing failure detection.
- **Work:** Change only the agreed development guidance, gate runner, or focused
  tests. Add negative coverage proving that an out-of-scope aggregate is not
  silently skipped when its trigger is present, and that a required focused gate
  cannot be bypassed. Keep the numbering follow-up and developer-instruction
  wording out of this diff.
- **QS:** Focused and triggered aggregate tests pass; failure, scope-drift,
  immutable-section, and logging behavior are covered; successful output is
  materially shorter; `git diff --check` passes.
- **Learnings:** Record measured wall-time/context savings and any newly exposed
  dependency before review.

## Phase 4 — Frozen independent review and closure

- **Goal:** Prove the optimized gate workflow reaches the same quality boundary
  with less time and context.
- **Work:** Freeze the result for `(Subagent Task: basix_verifier)` review. Require
  independent checks of the risk matrix, coverage mapping, escalation triggers,
  failure diagnostics, safe concurrency, and separation from both pending
  follow-up plans. Correct findings only after stopping/discarding the verifier
  result, then start a fresh verifier for the changed result.
- **QS:** No coverage gap or ambiguous trigger remains; measured savings are
  reported; all gates required by the final matrix pass; archive this plan and
  commit only task-related changes with a Conventional Commits message.
- **Learnings:** Preserve final matrix decisions, evidence, rejected shortcuts,
  and qualifying durable insights in the archived plan.

## Assumptions

- The current full suites remain available as escalation gates even when they are
  not run for a prose-only edit.
- “Without quality loss” means equivalent detection of semantic, installation,
  scope, security, and contract failures—not identical command count.
- Successful logs may be summarized, but failure evidence remains recoverable
  and sufficiently detailed for diagnosis.

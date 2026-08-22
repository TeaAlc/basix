# Developer Instruction Plan Filename Numbering

## Status and dependency

Deferred follow-up. Activate only after the separate developer-instruction
optimization plan has completed its implementation, independent review, archive,
and commit. This plan must produce a separate diff and commit.

## Overall goal

Require every newly created or saved plan to use a unique, monotonically
numbered filename so active and archived plans with the same logical name never
collide.

## Proposed policy

Use the form `plans/<stem>-NNN.md`, where `NNN` is a zero-padded decimal suffix
starting at `001` and immediately precedes `.md`.

- For a new logical `<stem>`, inspect both `plans/` and `plans/archive/` before
  saving; include active and archived files in the sequence.
- If no matching numbered file exists, use `001`. Otherwise use one greater than
  the highest existing valid suffix; never reuse a lower number or overwrite a
  file.
- A completed or replaced plan moves to `plans/archive/` with the exact same
  numbered basename.
- Existing unsuffixed plans are legacy files: do not rename them in this
  follow-up, but do not create another unsuffixed plan. A new plan using that
  logical stem starts at `001` unless numbered successors already exist.
- Numbering is per logical stem; unrelated plan stems have independent sequences.

Examples:

```text
plans/release-gate-001.md
plans/archive/release-gate-001.md  # after completion
plans/release-gate-002.md          # next plan with the same stem
```

## Ambiguity and behavior risks

- “Logical stem” must mean the basename with the final `-NNN.md` removed; do not
  compare only the full filename, or an archived `release-gate-001.md` could be
  missed when creating `release-gate-002.md`.
- Use the highest existing valid suffix plus one, rather than filling gaps, so
  numbers remain monotonic and never identify an earlier plan again.
- Scan exactly the active plan directory and `plans/archive/`; unrelated nested
  directories must not affect numbering.
- Treat malformed suffixes as non-numbered legacy names and preserve them; do
  not silently overwrite any existing path.
- Keep the optimization’s wording and tests frozen while implementing this
  follow-up; only the planning filename rule and its direct assertions may
  change.

## Phase 1 — Repository and lifecycle audit

- **Goal:** Identify every canonical instruction or test that governs plan
  creation, saving, updating, or archiving.
- **Work:** Reconfirm the canonical source and static-test locations; inspect
  existing plan files and ignore rules; define matching, malformed-suffix, gap,
  archive, and legacy fixtures.
- **QS:** The scope contains no unrelated plan-management implementation, and
  each proposed behavior has a concrete fixture.
- **Learnings:** Record interpretation decisions and durable memory candidates
  before implementation.

## Phase 2 — Independent policy implementation

- **Goal:** Add the numbered filename lifecycle without changing the preceding
  optimization’s behavior.
- **Work:** Update only the canonical `Planning` policy and its direct static
  assertions. Preserve all existing phase, dependency, replanning, compaction,
  and clarification requirements. Keep the numbering rule separate from those
  sentences and from the immutable `Basix agent spawning` category.
- **QS:** Assertions cover the `-NNN.md` format, `001` start, highest-plus-one
  increment, active/archive scan, exact-basename archive move, per-stem scope,
  no overwrite, legacy handling, and malformed-suffix handling.
- **Learnings:** Measure the incremental change and update only affected plan
  sections.

## Phase 3 — Verification and closure

- **Goal:** Prove the numbering policy is deterministic and independent of the
  preceding optimization.
- **Work:** Run focused static tests and all affected Basix/setup suites. Freeze
  the result for `(Subagent Task: basix_verifier)` review with the optimization
  commit as the immutable predecessor; correct findings only in a fresh cycle.
- **QS:** The optimization diff remains unchanged; numbering fixtures and all
  prescribed tests pass; no path is overwritten; archive the follow-up plan and
  commit only its task-related changes with a Conventional Commits message.
- **Learnings:** Preserve final fixture evidence, rejected ambiguity risks, and
  qualifying durable insights in the archived plan.

## Assumptions

- The policy governs plan-file naming in Basix-managed workflows; it does not
  rename historical plan files retroactively.
- “Same name” means the same logical stem, independent of active versus archive
  location and independent of the numeric suffix.
- This follow-up starts only after the optimization has passed its own tests,
  independent review, archive, and commit.

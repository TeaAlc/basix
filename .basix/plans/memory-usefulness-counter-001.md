# Memory usefulness counter

## Overall goal

Extend the Basix developer instructions so every memory insight records how many
sessions it demonstrably helped to solve work or prevent an error.

Estimated effort: small, well below 10 million input tokens. No per-phase
compaction decision is needed.

## Phase 1: Define and document the contract

- **Goal:** The memory schema and increment behavior are unambiguous.
- **Work:**
  - **Task 1:** Update `src/setup/developer_instruction.md` so every entry has a
    required non-negative integer `usefulness`, initialized to `0`. Keep
    `version = 1`; `Subagent Insight` retains its additional `subagent_type`.
  - **Task 2:** Specify that, at the final memory checkpoint before a commit, Root
    increments an entry by exactly `+1` when it was useful at least once during
    the session or prevented an error. Multiple uses in one session still count
    once; unused entries remain unchanged. When no commit occurs, apply the same
    rule at task completion.
  - **Task 3:** Update the memory summaries in `README.md` and
    `src/docs/agents.md` to match the normative instructions.
- **QS:** The instruction text defines the field, type, initial value, checkpoint,
  evidence threshold, and once-per-session behavior without conflicting with the
  existing memory-write checkpoints.
- **Learnings:**

## Phase 2: Migrate and validate repository memory

- **Goal:** The repository memory and static contract checks enforce the new
  schema.
- **Work:**
  - **Task 1:** Add `usefulness = 0` to every existing entry in
    `.basix/memory.toml` without changing insight text, category, date, or
    subagent provenance.
  - **Task 2:** Update `test/skills/basix/test-basix-static.sh` so normal entries
    require exactly `date`, `category`, `insight`, and `usefulness`, while
    `Subagent Insight` additionally requires `subagent_type`.
  - **Task 3:** Validate `usefulness` with an exact integer type check and a
    non-negative range check, explicitly rejecting missing values, booleans,
    negative integers, floats, and strings.
  - **Task 4:** Add assertions for the new normative wording and update valid
    in-test entry fixtures with counters.
- **QS:** Valid migrated entries pass; every listed invalid counter shape fails
  deterministically; the static test continues to validate the repository's
  actual memory file.
- **Learnings:**

## Phase 3: Verify and close

- **Goal:** The normative change is frozen, independently reviewed, and safely
  committed.
- **Work:**
  - **Task 1:** Run `bash test/skills/basix/test-basix-static.sh` for the memory
    contract and prose assertions.
  - **Task 2:** Run
    `bash test/setup/test-setup-support/test-setup-support.sh` for managed
    developer-instruction insertion and removal.
  - **Task 3:** Run `./test/verify-basix.sh` because the changed Basix static test
    participates in the aggregate suite.
  - **Task 4:** Freeze the result and obtain the required independent verifier
    review for the normative developer-instruction change. If remediation is
    needed, rerun the affected focused gates and restart the review.
  - **Task 5:** Apply the new `+1` rule to any memory entries demonstrably used in
    the implementation session, then commit only task-owned changes with a
    Conventional Commits message as Codex.
- **QS:** All selected tests finish successfully, the fresh verifier reports no
  unresolved findings, the usefulness review is complete, and unrelated changes
  such as `.codex/config.toml` remain untouched.
- **Learnings:**

## Assumptions

- `usefulness` measures useful sessions, not individual references within a
  session.
- The counter never decreases and is incremented only from concrete session
  evidence, not predicted future value.
- The existing memory format remains `version = 1`; this additive field does not
  introduce a separate compatibility mode or runtime parser.
- No ADR is required because the change is narrow, local, and readily reversible.

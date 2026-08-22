# Developer Instructions Targeted Optimization

## Overall goal

Shorten `Basix conventions`, `Planning`, and `Completion and commits` without
reducing information, introducing ambiguity, or changing agent behavior. The
optimized instructions should be at least 99% behaviorally identical in the
full managed-instruction context.

Estimated effort is far below 5 million tokens; no phase-by-phase compaction is
needed.

## Immutable scope and baseline

- Do not edit, reword, reorder, or move `## Basix agent spawning`.
- Do not move requirements between sections merely to make prose shorter.
- Preserve normative force, ordering, exceptions, actor names, paths, literals,
  and security constraints (`must`, `never`, `only`, `exactly`, `complete`).
- Baseline: `src/setup/developer_instruction.md` is 9,170 characters and 1,315
  words. `## Basix agent spawning` is 2,974 characters and 429 words and is
  excluded from all savings estimates.
- The current active plan is this file; archive it after successful review.
- After this optimization is implemented, reviewed, and committed, execute the
  independent deferred follow-up in
  `plans/developer-instruction-plan-numbering-001.md`. Do not combine its source,
  test, or review changes with this optimization.

## Candidate wording for implementation

These are controlled candidates, not permission to weaken a requirement. During
implementation, map every old clause to a new clause before deleting text.

### Basix conventions

```markdown
- Run Python with `PYTHONDONTWRITEBYTECODE=1`.
- Do not use gender-inclusive language unless the user explicitly requests it.
- Before using a Basix agent or specialized Basix skill, read the complete `basix` router skill.
- Before spawning a Basix agent, read the complete communication contract referenced by the router.
- Do not reread skill, agent, or reference instructions already in context unless the user explicitly requests it.
- For Scrapling MCP calls, the calling agent is the MCP client: generate and pass a cryptographically secure RFC 4122 UUID v4 as `client_id`; reuse it for related session calls and share it with a subagent only when deliberately sharing that session capability. Never log it or substitute `default`, a `session_id`, or a server-generated placeholder.
```

Risk notes:

- “Run Python” still applies to every Python invocation; “whenever” is filler.
- “Read the complete” preserves both the prerequisite and completeness; do not
  replace “Basix skill” with an unscoped “skill”.
- “Generate and pass” preserves the MCP client’s UUID-generation duty; the
  deliberate session-sharing condition and all forbidden substitutes remain.

### Planning

```markdown
## Planning

- Structure every plan as clearly bounded phases serving one explicit overall goal. Make phases as independent and self-contained as practical, and state required dependencies.
- Define each phase:
  - **Goal:** Required end state.
  - **Work:** Work packages and dependencies.
  - **QS:** Concrete completion checks.
  - **Learnings:** New findings, assumptions, risks, and decisions; assess durable insights for `memory.toml` and retain qualifying ones under the memory rules.
- Order work for maximum input-token efficiency without compromising correctness, safety, or mandatory dependencies. Delegate token-intensive, bounded work when its result outweighs the added context, marking it `(Subagent Task: <subagent_type>)`.
- Store the active plan as `plans/<name>.md`; move replaced or completed plans to `plans/archive/`. After each phase, update the remaining plan from its results; when new evidence can reduce risk, improve quality or workflow, save work, or materially reduce tokens, change affected parts while keeping the overall goal authoritative.
- Estimate total effort before work begins. Above 5 million expected tokens, ask whether to compact after every phase. If enabled, each phase closure must preserve, compactly but completely, everything needed to continue: findings, decisions, dependencies, and discovery results.
- Ask clarifying questions only when answers can materially affect scope, architecture, priorities, or implementation. Resolve material uncertainty iteratively; otherwise make and document reasoned assumptions.
```

Risk notes:

- The lifecycle and adaptive-replanning bullets are merged, but both triggers and
  the authoritative-goal rule remain explicit.
- “Each phase” remains attached to both phase updates and compaction closure;
  no phase may skip either applicable obligation.
- The four field labels, `QS`, memory assessment, delegation marker, archive
  paths, five-million-token threshold, and clarification boundary remain literal.

### Completion and commits

```markdown
## Completion and commits

- After `/root` finishes its changes, wait for every running verification and test to finish successfully. In a Git repository, then commit only the task's changes with a Conventional Commits message; never commit while any verification or test is running or has failed.
```

Risk notes:

- “Then” is conditional on the Git-repository clause, while the successful-test
  prerequisite applies everywhere.
- “Every running” and “any ... running or failed” preserve both the wait scope
  and the commit prohibition; the final completion rule remains unchanged.

## Phase 1 — Semantic audit and rewrite contract

- **Goal:** Freeze a clause-level contract proving that each current requirement
  survives the proposed wording and that the immutable subagent section is byte
  for byte unchanged.
- **Work:** Build an old-to-new crosswalk for all three editable sections;
  identify actor, trigger, ordering, scope, exception, security, and literal
  constraints. Record any candidate wording that could alter interpretation and
  reject it. Capture the current `## Basix agent spawning` content for exact
  pre/post comparison.
- **QS:** Every old clause has one unambiguous replacement; no requirement is
  represented only by implication; no immutable-section line is in the rewrite
  scope; estimated savings exclude that section.
- **Learnings:** Record accepted wording, rejected alternatives, and any
  cross-section interaction in this plan. Retain only durable qualifying insights
  in `.basix/memory.toml` under its existing rules.

## Phase 2 — Controlled implementation and regression coverage

- **Goal:** Apply only the audited wording changes and make regressions detect
  semantic loss or accidental edits to the immutable category.
- **Work:** Patch the three selected sections only. Update static assertions to
  check each preserved requirement, section order, exact literals, and absence
  of the old duplicate wording. Use the frozen diff and verifier baseline to
  prove that `Basix agent spawning` is unchanged; do not bake a large Git
  baseline or repository-dependent comparison into installed runtime tests. Keep
  tests robust to line wrapping but strict on normative content.
- **QS:** `git diff --check` passes; the changed hunk set excludes the immutable
  category; focused static tests pass; all existing Basix and setup aggregate
  tests pass.
- **Learnings:** Update only affected plan parts with measured character/word
  savings, test evidence, and any interpretation concern.

## Phase 3 — Frozen independent review and closure

- **Goal:** Establish at least 99% behavioral equivalence before committing.
- **Work:** Freeze all relevant writes and request `(Subagent Task: basix_verifier)`
  review. Require independent checks of the clause crosswalk, full-context
  interpretation, immutable-section equality, diff scope, installability, and
  all prescribed test results. Correct findings only after stopping/discarding
  the verifier result, then start a fresh verifier for the changed result.
- **QS:** No unresolved finding or ambiguity remains; measured savings are
  reported; the immutable category is unchanged; `bash
  test/skills/basix/test-basix-static.sh`, `bash
  test/setup/test-setup-support/test-setup-support.sh`, `./test/verify-basix.sh`,
  and `./test/test-setup.sh` pass; archive this plan and commit only task files
  with a Conventional Commits message.
- **Learnings:** Preserve final wording decisions, rejected ambiguity risks,
  evidence, and any accepted durable memory insight in the archived plan.

## Assumptions

- “99% identical” means no intentional change in trigger, actor, ordering,
  scope, exception, security behavior, or required output; token savings alone
  do not justify an interpretation change.
- The user’s prohibition applies specifically to `## Basix agent spawning`; the
  adjacent `## Agent management` section remains unchanged unless a later request
  explicitly expands scope.
- Existing documentation and standalone plans are not rewritten.

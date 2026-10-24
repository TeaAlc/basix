# Feature-plan execution

Overall goal: Make Basix reliably produce and execute coherent feature-sized,
opaque multiphase plans with bounded exploration and incremental merge QS.
Estimated input effort: 0.5–1 million tokens; no phase compaction requested.

Public result: Consistent planning/management/Git guidance, mechanical whole-plan
graph validation, updated docs and tests. No predecessor plans.
Executor: /root/feature_plan_execution_impl_20261024 (senior).
Branch: feat/feature-plan-execution.
Worktree: /tmp/basix-feature-plan-execution.
Baseline/expected target tip: ca33b12; no predecessor plans.
State: implementation frozen; final behavioral evaluation and review in progress.
Acceptance/result/integration identities recorded at closure.
Only read-only exploration/research children, at most two.
Root owns ADR activation, Git, acceptance, independent evaluation and final review.
Scope: src/skills/basix-planning/, management skill/contract, affected router and
development guidance, canonical public docs/README, directly affected tests and
quality-gate profile only if necessary. No native model or message-schema change.
ADRs: 0001, 0008, 0011, 0014, and user-confirmed 0015 bind.
Design: docs/design/plan-execution-model.md (requirements, not runtime authority).
Root efficiency-report decision: no report required.

Exact implementation scope (Phase 1 primary task in final column):

| Path | Work | Task |
| --- | --- | --- |
| README.md | Explain execution model | 2 |
| src/docs/agents.md | Describe executor limits | 2 |
| src/docs/architecture.md | Clarify feature plans | 2 |
| src/docs/skills.md | Document planning behavior | 2 |
| src/skills/basix-planning/SKILL.md | Route feature execution | 2 |
| src/skills/basix-planning/references/feature-execution.md | Define feature plan model | 2 |
| src/skills/basix-planning/references/parallel-git.md | Scope merge and final QS | 2 |
| src/skills/basix-subagent-management/SKILL.md | Account executor/helper slots | 2 |
| src/skills/basix-subagent-management/references/agent-communication-contract.md | Align opaque plan dispatch | 2 |
| src/skills/basix-planning/references/whole-plan-validation.md | Define whole-plan schema | 3 |
| src/skills/basix-planning/references/dependency-validation.md | Keep task checks intra-plan | 3 |
| src/skills/basix-planning/scripts/validate-work-order.py | Check graph and capacity | 3 |
| test/skills/basix-planning/test_validate_work_order.py | Test graph failure boundaries | 3 |
| test/skills/basix-agent-authoring/test_silent_policy.py | Align contract assertions | 4 |
| test/skills/basix/test-basix-static.sh | Align capacity assertions | 4 |

Root-only administrative scope: ADR 0010 archive, ADR 0015 and both ADR indexes;
this plan; memory instruction update; design-document implementation status.

## Phase 1: Implement consistent feature-plan rules

**Goal:** Skills, docs and graph checks express the approved execution model.

**Work:**
1. **Task 1:** Reconcile authoritative requirements and affected consumers.
2. **Task 2:** Implement feature-sized opaque plan dependencies, executor ownership,
   capacity accounting and scoped merge/final QS; preserve existing obligations.
3. **Task 3:** Add bounded whole-plan validation and meaningful failure tests;
   preserve the existing intra-plan source-dependency validator.
4. **Task 4:** Update dependent assertions/docs and run focused checks. Depends on 2–3.

**QS:** Focused planning, silent-policy and static tests pass. Coverage includes
whole-plan cycles/unknown dependencies, opacity, sequential shared-file ownership
and capacity constraints supported by the validator's declared contract.

**Learnings:** Whole-plan graph validation complements the existing intra-plan
validator without changing its contract. Focused planning (18 tests), silent
policy (10 tests) and static checks pass; production and test helper docstrings
document every parameter. Initial forward evaluation exposed ambiguous internal
implementation delegation labels; Phase 2 corrected the skill, not its outputs,
and started a fresh independent evaluation. Logs:
`/tmp/basix-feature-plan-execution-checks/cycle3/`.

## Phase 2: Independent behavioral evaluation and final acceptance

**Goal:** Fresh planning outputs demonstrate the skill behavior and final policy
changes pass aggregate verification and frozen independent inspection.

**Work:**
1. **Task 1:** Root accepts Phase 1 result and creates a scoped feature checkpoint
   only if current commit rules permit it; otherwise retains the frozen diff.
2. **Task 2:** Independently generate plans in temporary storage for small and
   complex work, semantic merges, joins and failures; never repair generated plans.
3. **Task 3:** Executor corrects evidenced skill defects and reruns affected checks;
   repeat fresh evaluation if needed. Depends on evaluation findings.
4. **Task 4:** Root runs final Basix aggregate and obtains frozen review of the exact
   final result, integrates safely, archives this plan and commits task changes.

**QS:** Behavioral outputs respect whole-plan dependencies and ownership, no
implementation grandchildren, requested capacity subject to actual tool limits,
incremental merge QS and final aggregate. All started checks pass; independent
review has no unresolved findings. Temporary planning artifacts are removed.

**Learnings:**

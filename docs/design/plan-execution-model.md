# Feature-sized plans and incremental merge verification

Status: design discussion, not an activated runtime policy.

This document records the user's requirements and the Root/Miraculix discussions.
It does not replace active skills, communication rules or ADRs. In particular,
ADR 0010 still limits current execution to three active descendants overall.

## Work-order structure

Root normally performs planning, using serial or parallel read-only exploration
and research when useful. Split a work order into a useful number of coherent
plans: usually one feature per plan, or several small related features together.
A small task may need only one plan. Do not minimize plan count, maximize it, or
split merely to occupy available agent slots.

Each implementation plan has one responsible executor, one feature branch and
one separate worktree. Its internal phases structure its own implementation.
The executor performs the implementation itself; it may delegate only read-only
exploration/research. Root owns coordination, acceptance, shared Git operations,
checkpoint commits, integration and target updates.

Choose plan boundaries using these questions:

- Does each plan deliver a coherent, independently verifiable result?
- Can it be assigned using its public inputs, outputs and acceptance criteria?
- Are its scope and resource requirements manageable for one executor?
- Does splitting improve useful parallelism, risk control or responsibility enough
  to justify dispatch, context, verification and integration overhead?
- Can concurrently ready plans write disjoint scopes using isolated resources?

Group small features that share implementation files, contracts and acceptance.
A reusable enabling capability can be its own plan; preparation needed by only
one feature normally remains inside that feature. Repeated cross-branch edits,
private sequencing dependencies, excessive handoffs and mostly waiting executors
indicate poor decomposition. Stop splitting when another split adds no justified
benefit. No fixed number of plans, phases or files determines the answer.

## Opaque plans and whole-plan dependencies

The authoritative dependency graph is an acyclic graph of whole plans. An edge
means that the predecessor is complete, checked, verified, Root-accepted and
integrated before the dependent plan starts. Bind its accepted result to an exact
commit and the relevant public contract/evidence.

A plan must not depend on, name or inspect another plan's internal phases, tasks
or intermediate checkpoints. There are no partial cross-plan handoffs. Root may
inspect every plan for coordination, but dispatches consumers using only the
predecessor's agreed public result and acceptance evidence.

If A needs B and B also needs later work from A, the cut is invalid. Extract a
real shared foundation into a predecessor plan, combine the coupled work, or
restructure the features. Do not solve the cycle through phase-level edges.

Synchronization waits for named complete predecessor plans, not unrelated work.
A join is a coordinator condition, not an otherwise empty plan. An integration
plan is appropriate only when it contains substantive implementation or testing
work with its own result and acceptance criteria.

## Ownership, agents and capacity

Exact write ownership is exclusive among concurrently executing plans. A serial
successor may modify the same files after the predecessor is inactive, accepted
and integrated, with explicit ownership transfer and a new accepted baseline.
Shared interfaces have one active owner. Resources, outputs and logs are isolated
per worktree and per mutable check environment.

Requested capacity model:

- At most three simultaneously active plan executors; this is not a limit on the
  total number of plans in the work order.
- Each executor may run up to two read-only exploration/research children at once,
  serially or concurrently within its phases. No implementation children.
- These permissions require a suitable senior executor and explicit assignment
  restrictions; preserve applicable native specialization/model rules.

Recommended additional accounting: at most six active read-only helpers and nine
active descendants overall, excluding Root. Root-direct exploration, research and
verification also consume this read-only capacity. This shared-pool detail is a
proposal, not an additional user-specified limit. Actual runtime capacity is a
harder cap; throttle dispatch rather than promise unavailable parallelism.

Children finish before their executor's terminal result. Inactivity, terminal
delivery, successful checks, Root acceptance and integration are separate states.
An interrupted executor may resume with its existing plan/branch after explicit
continuation and capacity checks. Replacement requires predecessor inactivity
and explicit exclusive transfer of work, evidence and responsibility.

Internal checkpoints are permitted for recovery and compaction, but never release
another plan. Plan phases retain Goal, ordered Work, QS and initially empty
Learnings; populate Learnings only after the full phase QS succeeds. The previous
proposal for inter-plan phase/checkpoint cycles is explicitly discarded. Ordinary
internal phase completion needs no transmitted intermediate result or new message
type. Contract 2.0's terminal/continuation rules remain the starting point.

## Compact coordination record

Root keeps one small work-order index referencing authoritative plan documents
and inventories rather than copying them. Record plan IDs/paths, public inputs
and outputs, whole-plan dependencies, executor, branch/worktree, ownership and
resource references, baseline/result commits, completion/acceptance/integration
states, and the target branch's expected tip. No additional nested master phase
plan is needed just to duplicate this index.

Before parallel dispatch, check dependency references and cycles, scope/resource
overlaps, accepted predecessor identities and available capacity. Keep the existing
file/task graph checks, but do not expose predecessor internals through them.
A compact whole-plan graph check should complement file-level validation.

## Quality assurance: healthy main, scoped merges, final whole-task gate

The user's requirement is to assume that the main branch is functional. Do not
repeat the full project/whole-task test suite for every plan merge. Test the whole
system once at the end of the work order, after all plans are implemented and
integrated. Earlier plan-specific and merge-specific checks remain necessary.

There are three distinct verification scopes:

1. **Plan result:** the executor runs the checks required to establish its feature
   and public contract. Root verifies the frozen result against that plan's scope.
2. **Merge candidate:** Root selects checks for the changed behavior, interactions
   with intervening target changes, and any conflict resolution. Reuse applicable
   accepted plan and target evidence; no automatic full-suite rerun.
3. **Completed work order:** with every plan integrated and writers inactive, run
   the required whole-task/system checks and final frozen review on the exact
   integrated tree. The task remains incomplete until this gate passes.

For each merge, record the feature baseline, expected target tip, feature result
and candidate tree; inspect the incoming delta, relevant target changes since the
feature baseline, conflict-resolution edits and changed toolchain/environment
inputs. Textually clean merges can still introduce semantic
interactions. Select the narrowest sufficient checks covering those effects and
record why existing evidence remains applicable elsewhere.

Reuse evidence only where the checked code and its relevant contracts,
configuration, dependencies and environment assumptions remain applicable. Bind
reused evidence to the candidate and identify its original scope; an accepted
feature commit alone does not prove a rebased, squashed or merged candidate.
Neither scoped merge acceptance nor healthy-main assumptions mean the candidate
has passed whole-system testing.

Conflicts in shared APIs, dependency/toolchain settings, build/test configuration,
schemas or security boundaries may require broader checks than the conflict's
file alone. Broaden according to demonstrable impact or unresolved uncertainty,
not merely because a merge occurs. If a broad aggregate is genuinely the only
sufficient check for the affected surface, record that reason rather than claim
that a narrow check proves more than it does. Such an exception is not the default
whole-task gate repeated after each plan.

If impact is unclear, first resolve it through bounded inspection or exploration.
If sufficient coverage still cannot be justified, withhold the affected merge
until Root selects adequate additional checks; do not silently assume independence.

Target drift invalidates the old merge candidate: derive a new candidate and
reassess affected evidence/checks. Do not automatically discard independent evidence
or rerun the full suite. Review any resolution/new code against a frozen candidate;
reuse an unchanged accepted feature review for its still-applicable scope.
Reviewing only resolution edits is sufficient only if they cannot change relevant
interactions; otherwise include the affected callers, contracts or configuration.

Keep a compact merge record: baseline, target and feature identities; candidate
tree; affected deltas/conflicts and repair owner; impact rationale; selected
checks/results; reused or invalidated evidence; review scope/result; acceptance.
Reference existing evidence instead of copying logs or check inventories.

| Merge effect | Appropriate incremental checks |
| --- | --- |
| Documentation-only change with no executable/configuration effect | Relevant links, formatting and documentation consistency |
| Clean feature merge alongside a changed shared API | Feature checks and affected API/consumer contracts |
| Resolved security or build configuration conflict | Affected security/build checks, broadened to the required boundary |

These examples illustrate selection, not fixed gate mappings; actual impact
determines the checks.

Root updates the target only after selected merge checks pass, using a guarded,
worktree-safe update preserving unrelated user changes. Corrections go to the
primary owner or an explicitly transferred replacement. Retest/review affected
scope; never bypass ownership by treating a merge as permission for arbitrary edits.

If evidence shows main is unhealthy, do not silently rely on the assumption. Root
identifies the affected scope and separates existing failures from introduced ones
before accepting dependent results. Pause affected descendants while independent
plans may continue. Final-gate failure keeps the work order open;
perform a bounded repair under explicit ownership, then rerun affected checks and
the full final gate for the corrected integrated result. Thus one successful final
gate is required on the stable final candidate; a failed run followed by changes
necessarily requires another run. No deployment follows merely
from a successful local merge.

Existing commit/check permissions remain binding. Use allowed commit windows;
do not invent a scoped-checkpoint exception when active policy does not permit it.

## Expected implementation boundaries

- Planning skill: feature decomposition, opaque whole-plan graph, compact index,
  executor responsibility and scoped versus final QS.
- Parallel Git reference: one branch/worktree per plan, accepted whole-plan
  baselines, incremental merge evidence and final whole-task verification.
  Existing guidance already allows accepted subsets and risk-based feedback;
  distinguish intermediate integration from the final integrated-result gate.
  Its explicit aggregate/review requirement after target drift needs adjustment
  to permit scoped reassessment before the final whole-task gate.
- Management skill and communication contract: executor/helper accounting and
  restricted nested delegation; retain silent work and direct-parent delivery.
- Router/authoring references where authority or capacity wording is affected;
  preserve native role/model settings unless a real change is necessary.
- Whole-plan graph validation plus focused behavioral tests for decomposition,
  opaque dependencies, cycles, ownership, capacity and evidence invalidation.
- Relevant docs/static/contract tests and an explicitly confirmed ADR 0010
  successor before activating the changed capacity policy. Assess ADR 0014 for
  compatibility; do not silently rewrite a binding decision.

Behavioral test outputs must remain temporary. Do not retain another fictional
project or generated demo plan as permanent repository test data.

## Miraculix conclusions and implementation follow-up

The follow-up discussion supports three separate scopes: plan acceptance,
incremental merge acceptance and final whole-task verification. The compact merge
record above supplies the minimum rationale without another heavyweight inventory.
Evidence reuse is conditional on unchanged relevant assumptions, not merely an
unchanged file or successful textual merge. Conflict repair retains explicit
ownership, and final failures keep the work order open.

Source inspection identifies existing building blocks rather than a need for a
new merge-testing subsystem:

- `src/skills/basix-planning/references/parallel-git.md` already separates local
  acceptance, subset integration and final aggregate/frozen review. Its target-drift
  rule explicitly reruns aggregates and therefore needs deliberate revision.
- `src/scripts/run-quality-gates.sh` already accepts changed paths, impact,
  immutable hashes, review evidence and log destinations. It has no automatic
  merge-state or target-tip tracking; Root must supply those facts.
- `src/scripts/quality-gates/basix.sh` maps component/interface/runtime impacts to
  aggregates. During implementation, distinguish justified merge checks from
  final aggregate requirements without weakening mandatory boundary coverage.

Validate the eventual skill changes using temporary independent planning runs
covering one-plan work, useful parallel branches, whole-plan joins, shared-file
serial successors, semantic clean merges, conflict repair, target drift and final
gate failure. Judge plans generated by the skill; do not repair test plans to
conceal skill defects. No normative skills, scripts or ADRs are changed by this
design document.

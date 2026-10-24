# Parallel Git writers

Read this reference before planning or executing parallel Git writers. General
dependency readiness and named-result joins remain in the planning skill;
Contract 2.0 governs delivery, inactivity and acceptance. Read-only agents need
no feature branch or worktree. This workflow grants no additional write, commit,
push or destructive-operation authority.

## Establish isolated writers

Root records the integration target, its expected tip and each writer's exact
baseline. Use the earliest accepted base containing that writer's actual required
predecessors; check inherited source requirements rather than assuming a baseline
adds no dependencies. A dependent writer starts from the accepted integrated
predecessor base, not a stale original baseline. Unrelated wave members need not
finish first. Freeze disjoint write scopes and shared interface
contracts before dispatch. Overlapping scopes or an unsettled interface require
sequential acceptance or explicit replanning.

Give each complete feature plan one responsible executor, a task-owned feature branch and separate worktree, plus isolated
logs, generated outputs and other mutable resources. Shared Git metadata and ref
operations are serialized by root: branch/worktree creation, commits, merges,
ref updates and removal. Writers edit and run assigned local checks within their
owned worktree; they do not commit or manipulate shared refs. Root records exact
resource identities and ownership so recovery cannot target unrelated work.

## Accept and checkpoint individual results

Each writer completes its scope-local checks and delivers its terminal result.
Root establishes inactivity and accepts the result separately; neither passing
tests nor a finished tool implies delivery, inactivity or acceptance. Failed or
unverified scope is not accepted and its descendants remain blocked.

Only root creates a feature checkpoint commit, limited to the accepted writer's
task changes after that writer is inactive and its assigned scope-local checks
have passed, with no unresolved relevant failure. Future integration checks are
not checkpoint prerequisites. Existing commit permissions and required gates remain binding: no scoped
checkpoint exception is granted here. Never commit changing, failed or unverified
scope, and never stage another task's or the user's changes.
Record the exact accepted checkpoint SHA and evidence for integration.

## Integrate and verify

Root merges exact accepted SHAs in dependency order into a task-owned integration
branch and worktree. Named joins require only their declared predecessors; an
unrelated running task is not an integration barrier. Resolve conflicts only
within authorized scope. Corrections invalidate affected acceptance and test
evidence: rerun affected checks and obtain new acceptance before proceeding.
Integrate accepted subsets when they enable meaningful risk-based feedback,
using the checks and infrastructure needed for that subset; retain the final gates
below for the complete integrated result.

For each merge candidate, record feature baseline, expected target tip, exact
feature result and candidate tree. Inspect the incoming delta, relevant target
changes since the feature baseline, conflict-resolution edits and changed
configuration, dependencies, toolchain or environment assumptions. Clean textual
merges may still change semantic interactions. Root selects the narrowest
sufficient affected behavior/interaction/conflict checks, with impact rationale;
no automatic full-suite rerun for each plan. Shared API, schema, security or
build/test conflicts may need broader boundary checks. If impact is unclear,
first use bounded inspection; withhold the affected merge if adequate coverage
still cannot be justified. An aggregate may be necessary for demonstrable impact
or unresolved uncertainty; record why rather than making it the merge default.

Reuse accepted plan/target evidence only where checked code, relevant contracts,
configuration, dependencies and environment assumptions remain applicable. Bind
reuse to the candidate and original scope; a feature SHA alone does not prove a
rebased, squashed or merged candidate. Record baseline/target/feature identities,
candidate tree, affected deltas/conflicts and repair owner, impact rationale,
selected checks/results, reused/invalidated evidence, review scope and acceptance.
Reference existing evidence rather than copying logs. Corrections retain explicit
ownership, invalidate affected evidence and require affected checks and frozen
review. Reuse an unchanged accepted feature review only for its applicable scope;
review resolution/new code and affected interactions on the frozen candidate.
Reviewing resolution edits alone suffices only if relevant interactions cannot
change. All overlapping writers must be inactive throughout the review freeze.
All selected checks/reviews must pass before the guarded target update.

After every plan is integrated and writers are inactive, run required whole-task
aggregate checks on the integrated result and final frozen independent review of
the exact final candidate. Intermediate merge acceptance is not whole-system
test evidence. Final failures keep the work order open; assign bounded repair,
rerun affected checks and the full final gate for the corrected result.

Root atomically guards the target update against its recorded expected tip
(compare-and-swap or exclusive coordination) and confirms the proposed update
contains the exact integrated tested tree; comparing then blindly updating is
insufficient. Keep any checked-out target's index/worktree consistent through a
worktree-safe update that preserves unrelated changes; a raw ref update alone
does not suffice there. If the target drifted, the old candidate is invalid: incorporate the new accepted
base and derive a new candidate, reassess affected checks/evidence and obtain a
new frozen review for changed scope before retrying the guarded update. Reuse
independent evidence whose assumptions still hold; target drift alone does not
require another aggregate. The complete final candidate still needs the final gate. Never force-overwrite intervening changes. Updating a local target does
not imply permission to push or publish.

## Failure and cleanup

Failure blocks descendants, not independent accepted work, unless shared
invariants changed. Root explicitly replans deferred scope and preserves exact
SHAs, unmerged work and recoverable logs for diagnosis or continuation. Remove
only identified task-owned branches, worktrees and resources after checking for
unmerged or uncommitted work and preserving anything needed for recovery. Never
reset, discard or clean the user's changes as part of isolation or cleanup.

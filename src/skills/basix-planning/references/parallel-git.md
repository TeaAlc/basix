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

Give each writer a task-owned feature branch and separate worktree, plus isolated
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
not checkpoint prerequisites. Under the active developer policy's scoped
checkpoint exception, unrelated writers or checks may continue. Never commit changing, failed
or unverified scope, and never stage another task's or the user's changes.
If the active policy does not permit the exception, wait for its required gates.
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

Run aggregate checks on the integrated result, then obtain a frozen independent
review before updating the target. Record the tested tree and reviewed result;
all overlapping writers must be inactive and the review freeze lasts through
completion under Contract 2.0. Any correction to the reviewed target requires
affected checks and a new frozen review cycle. All checks and reviews covering
the integrated scope must finish successfully before target update.

Root atomically guards the target update against its recorded expected tip
(compare-and-swap or exclusive coordination) and confirms the proposed update
contains the exact integrated tested tree; comparing then blindly updating is
insufficient. Keep any checked-out target's index/worktree consistent through a
worktree-safe update that preserves unrelated changes; a raw ref update alone
does not suffice there. If the target drifted, incorporate its new accepted base, reintegrate, rerun affected
and aggregate checks, and obtain a new frozen review before retrying the guarded
update. Never force-overwrite intervening changes. Updating a local target does
not imply permission to push or publish.

## Failure and cleanup

Failure blocks descendants, not independent accepted work, unless shared
invariants changed. Root explicitly replans deferred scope and preserves exact
SHAs, unmerged work and recoverable logs for diagnosis or continuation. Remove
only identified task-owned branches, worktrees and resources after checking for
unmerged or uncommitted work and preserving anything needed for recovery. Never
reset, discard or clean the user's changes as part of isolation or cleanup.

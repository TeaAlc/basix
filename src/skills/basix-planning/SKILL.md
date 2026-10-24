---
name: basix-planning
description: "Basix-Skill: Use before creating, revising, executing, completing, or archiving a saved phase plan."
---

# Basix Planning

Read the complete `basix` router, then [basix-adr](../basix-adr/SKILL.md), the active ADR index and
relevant active ADRs before planning; active ADRs bind. For managed assignments,
load and follow the router's mandatory management/Contract 2.0 boundary, including
model/effort precedence, specialist routing, defaults, no-fork dispatch,
unsupported-setting rejection, complete assignments and lifecycle rules. Saved
plans are not transmitted; Contract 2.0 owns message cycles.

## Plan structure and lifecycle

Serve one explicit overall goal with bounded, as independent and self-contained
as practical phases and stated dependencies. Define each phase briefly in order:

- **Goal:** Required end state.
- **Work:** A numbered list labeled **Task 1:** through **Task n:** in topological
  presentation order; explicit dependencies govern execution, including across phases within this plan.
- **QS:** Concrete completion checks.
- **Learnings:** Empty initially; populate only after the entire phase QS succeeds,
  with findings useful to later phases, never placeholders such as `Pending`.
  Before assessing/retaining durable findings in `memory.toml`, load and follow
  [basix-agent-memory](../basix-agent-memory/SKILL.md).

Optimize input-token efficiency without compromising correctness, safety or
mandatory dependencies. Name the implementation executor once at plan level.
Within its phases, `(Subagent Task: <subagent_type>)` labels identify only explicitly
granted read-only exploration/research children, never the executor's implementation.
Delegate those bounded reads when their benefit outweighs added context.
For discovered bug/feature
files, list every affected file with a work description of at most 32 characters,
inline or through a complete canonical manifest. For a manifest, record its stable
path and full content hash; verify it exists, is readable and matches that identity.
Map exact scope IDs to primary task owners, with every path and its short work
description in the manifest; IDs/ranges must resolve unambiguously with no missing
or duplicate ownership. Revalidate affected scope and replan when it changes.
Small inventories need no manifest.
Keep shared invariants, dependencies and inventories authoritative in one place,
with task-specific deltas rather than repeated copies. Dispatch assignments must
still contain independently complete context under management's rules.
Estimate total effort before work; above 10 million expected input tokens, ask
whether to compact after every phase. If enabled, preserve all continuation
findings, decisions, dependencies and discovery results compactly at phase closure.

Save new plans as `.basix/plans/<stem>-NNN.md`. Inspect only direct files there
and in `.basix/plans/archive/`, ignoring other nested directories. A valid suffix
is canonical decimal, at least three digits, zero-padded only to width three
(`001`, `010`, `999`, `1000`; never `000`, `01`, `0001`). Derive the logical stem
by removing a final valid `-NNN.md`; allocate independently per stem: `001` if none
exists, otherwise highest valid suffix plus one across both directories. Never
reuse a lower number or overwrite a path. Preserve unsuffixed and malformed
legacy files without renaming or counting them; create no new unsuffixed plan.

After each phase, update remaining work from its results; revise affected parts
when evidence reduces risk, improves quality/workflow or saves effort/tokens, preserving
the overall goal. Move completed/replaced plans to the archive with their exact
numbered basenames. Root owns plan consolidation, approval/ADRs, dispatch, review,
archival and commit; executors may write only explicitly assigned implementation,
checks, plan checkpoints and requested analysis. Read-only agents propose changes.

## Feature plans and dependencies

Root normally plans the work order, using read-only exploration/research as useful.
Read [feature-execution.md](references/feature-execution.md) completely before
choosing plan boundaries or dispatching a plan. Choose coherent feature-sized
plans, including several small related features when they share implementation
and acceptance; a small task may need only one plan. Do not optimize plan count
or split to fill slots. Each plan has one responsible executor, branch and worktree.
Internal phases belong to that executor. Cross-plan dependencies name only whole
completed, checked, verified, Root-accepted and integrated predecessor plans;
never another plan's phases, tasks or intermediate checkpoints.

## Dependencies and parallel work

Within each plan, audit actual dependencies, including those introduced by baselines, phase gates,
shared resources and acceptance aggregation. Distinguish source prerequisites,
semantic readiness for implementation and readiness for integration/release;
integration needs must not silently become extra intra-plan implementation blockers.
Whole-plan predecessors still require complete integration before consumer start. Retain genuine
safety and contract gates; explain extra gates that constrain otherwise independent
work. Phase labels and waves create no implicit global barrier.
Before finalizing a multi-plan work order, validate its whole-plan graph using
[whole-plan-validation.md](references/whole-plan-validation.md). This complements,
and never replaces, the following intra-plan source/task check.
Before finalizing parallel tasks within a plan with explicit machine-readable file dependencies,
mechanically reconcile full-inventory ownership, direct intra-plan task source inputs and
start conditions; record the validation command, input identities and result.
Read [dependency-validation.md](references/dependency-validation.md) for the
normalized contract and validator. Do not substitute future implementation tests
for this planning evidence.

A task is ready when named predecessors and required inputs/contracts are accepted
by their responsible parents, ownership/scope is clear, concurrent writes are
disjoint, mutable resources/logs are isolated and management's slot capacity is
available under management's executor/helper limits and the harder runtime cap. Predecessor-free tasks still need the
other conditions. Parallel implementation runs across independent whole plans;
within a plan, delegated parallel work is limited to granted read-only
exploration/research. Parallelize only when expected benefit outweighs
dispatch/context/synthesis costs; choose phases for the goal, not a universal sequence.
For parallel tasks or handoffs only, record needed dependencies/results,
owner/scope, accepted inputs/contracts, resources/logs, acceptance checks and
synthesis/integration owner. Ordinary serial work needs no parallel template.

Schedule the earliest meaningful partial integration or feedback for the risks at
hand. Stage harness/infrastructure work to support the next useful checks rather
than automatically requiring a complete harness before all implementation. Plan-specific and incremental merge checks supplement required final whole-task
aggregate checks and frozen independent review;
they do not replace them. Choose their scope and timing from actual dependencies
and risks, not a universal sequence.

Joins await named accepted results, not every agent or a phase boundary. Contract
2.0 distinguishes terminal delivery, inactivity, passing checks and parent
acceptance. Failures block descendants; independent work may continue unless
shared inputs/contracts/invariants changed, requiring reassessment. Root explicitly
replans omitted/deferred scope; early result acceptance never permits premature
phase Learnings. Isolation and synthesis apply to research and non-Git work too.
Before planning/executing parallel Git writers, read
[parallel-git.md](references/parallel-git.md) completely; read-only work needs no branch.

## Continuation and optional reports

Before compaction, save minimal continuation state in the assigned plan/checkpoint:
task/goal, next steps, owned scope/resources/permissions, decisions, completed QS
and log paths, blockers, report flag, contract version, logical sequence and cycle
revision. Never put transient state in memory. Resume without a transmitted plan,
status message or context fork; Learnings still require successful QS.

Root explicitly decides whether each task requires material efficiency analysis,
normally at dispatch; it is not compulsory. Check for an adjacent
`foo-001_efficency_analysis.md` when dispatching, updating, replacing or archiving
`foo-001.md`. Before assigning/performing requested analysis or handling an existing
companion (even without a new report request), read
[efficiency-analysis.md](references/efficiency-analysis.md)
completely and follow its permissions, evidence and paired-lifecycle rules.

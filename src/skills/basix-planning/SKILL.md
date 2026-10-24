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
  presentation order; explicit dependencies govern execution, including across phases.
- **QS:** Concrete completion checks.
- **Learnings:** Empty initially; populate only after the entire phase QS succeeds,
  with findings useful to later phases, never placeholders such as `Pending`.
  Before assessing/retaining durable findings in `memory.toml`, load and follow
  [basix-agent-memory](../basix-agent-memory/SKILL.md).

Optimize input-token efficiency without compromising correctness, safety or
mandatory dependencies. Delegate bounded work when its benefit outweighs added
context, labeling tasks `(Subagent Task: <subagent_type>)`. For discovered bug/feature
files, list every affected file with a work description of at most 32 characters.
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

## Dependencies and parallel work

A task is ready when named predecessors and required inputs/contracts are accepted
by their responsible parents, ownership/scope is clear, concurrent writes are
disjoint, mutable resources/logs are isolated and management's slot capacity is
available (maximum three active descendants, including nested children). Predecessor-free tasks still need the
other conditions. Parallelize planning, research or implementation only when
expected benefit outweighs dispatch/context/synthesis costs; choose phases for
the goal, not a universal sequence.
For parallel tasks or handoffs only, record needed dependencies/results,
owner/scope, accepted inputs/contracts, resources/logs, acceptance checks and
synthesis/integration owner. Ordinary serial work needs no parallel template.

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

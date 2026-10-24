# Whole-plan graph validation

Before finalizing a multi-plan work order and after changing its graph, ownership
or capacity snapshot, normalize its authoritative index into temporary JSON and run:

```bash
PYTHONDONTWRITEBYTECODE=1 python <skill-dir>/scripts/validate-work-order.py work-order.json
```

Record command, result and full input SHA-256 printed on success. Exit 0 means
mechanical validity; exit 1 returns a controlled JSON error. The read-only,
dependency-free utility is not a scheduler and does not inspect Git, saved prose,
acceptance evidence or actual agent state. Root reconciles the adapter with the
complete index and verifies these operational facts before dispatch. Never discard
an edge or scope to make validation pass. Temporary JSON stays outside the repo.

## Exact normalized schema

The root object has exactly `plans` (nonempty array) and `active` (snapshot).
Every plan has exactly:

- `id`: unique opaque lowercase slug matching `[a-z][a-z0-9-]*`.
- `depends_on`: unique whole-plan ID strings. Unknown IDs, self edges and cycles
  fail; strings containing phase/task/checkpoint selectors cannot resolve IDs.
- `writes`: unique normalized relative POSIX paths, without `..`, backslashes,
  absolute paths, globs or aliases. Enumerate exact files or directory scopes;
  Root resolves filesystem aliases before normalization.
- `resources`: unique nonempty IDs for exclusive mutable resources/logs/outputs.

Unknown fields are rejected everywhere, including phase/task-level dependency
objects. IDs denote whole plans exclusively; the adapter must not relabel phases
as plans. Textual slug spelling cannot prove a coherent feature boundary.
Overlapping paths (including directory ancestors) or shared exclusive resource
IDs require a predecessor relationship in either direction. This admits serial
successors, not concurrent shared ownership; Root still explicitly transfers
ownership after predecessor inactivity, acceptance and integration.

`active` has exactly `executors` (array), `root_helpers` (nonnegative integer)
and `runtime_limit` (positive integer, total actual agent slots including Root).
Each executor has exactly `plan` (known unique ID) and `helpers` (integer 0–2,
read-only exploration/research only). The proposed snapshot admits at most three
executors, six read-only helpers including Root-direct exploration/research/review,
and nine descendants excluding Root, further bounded by `runtime_limit - 1`.
An active predecessor and consumer together fail. Zero active agents is valid.
The utility checks declared counts, not spawn authority, role settings, actual
inactivity, predecessor acceptance, resource isolation or available runtime slots.
Root must establish those facts separately and throttle dispatch accordingly.

This whole-plan schema deliberately contains no internal phases/tasks or partial
handoffs. The existing `validate-plan-graph.py` and its
[normalized source/task contract](dependency-validation.md) remain separate,
unchanged checks within a plan; never use their task edges between plans.

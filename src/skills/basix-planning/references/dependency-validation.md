# Mechanical dependency reconciliation

Use this workflow before finalizing parallel plans whose source inventory has
explicit machine-readable file dependencies. Adapt the complete authoritative
inventory and proposed plan into the normalized JSON below; do not infer source
edges from runtime, schema, migration or deployment relationships. Simple tasks
without such an inventory need no sidecar or normalization ceremony.

Run the read-only, dependency-free validator:

```bash
PYTHONDONTWRITEBYTECODE=1 python <skill-dir>/scripts/validate-plan-graph.py inventory.json plan.json
```

Temporary adapter outputs and evidence may live outside `.basix`; quality-gate
commands must use those paths. The utility reads only its two inputs, writes JSON
to stdout and exits 0 on success or 1 on controlled validation failure. Record the
command, result and both full SHA-256 input identities with the plan's validation
evidence. Reconcile discrepancies before finalization; rerun when either input
changes. These are planning checks, not evidence that implementation tests passed.

## Normalized contract

Inventory:

```json
{"files":[
  {"id":"api","path":"src/api.py","work":"Define interface","dependencies":[]},
  {"id":"consumer","path":"src/consumer.py","work":"Use interface",
   "dependencies":[{"file":"api","kind":"source"}]}
]}
```

Plan:

```json
{"tasks":[
  {"id":"interface","files":["api"],"source_inputs":[],"start_conditions":[]},
  {"id":"implementation","files":["consumer"],
   "source_inputs":[{"file":"api","owner":"interface",
                     "accepted_identity":"accepted:interface/interface-checkpoint"}],
   "start_conditions":[{"task":"interface","kind":"source"}]}
]}
```

File IDs, task IDs and paths are unique nonempty strings. `work` is nonempty and
at most 32 Unicode characters. Each inventory file has exactly one primary task
owner, with no unknown owned files. Dependencies name known file IDs and an
explicit kind: `source`, `runtime`, `schema`, `migration`, `deployment`, `semantic`,
`resource`, `acceptance` or `baseline`. Only `source` derives implementation
inputs; the other kinds retain distinct meaning without creating a source edge.
Every file must explicitly contain a normalized `dependencies` array, including
`[]` when empty; foreign dependency fields are not interpreted. Extra metadata
may preserve adapter provenance. Raw runtime/deployment gates that do not name
inventory files remain metadata and, when they constrain readiness, justified
task start conditions; do not fabricate file IDs for them.
The adapter must preserve all original entries and their semantics, expanding
scope IDs/ranges completely; review its coverage against the original inventory.
The validator cannot detect information an adapter silently discards.

For every direct cross-owner source dependency, `source_inputs` must name the
required file, its actual owner and a nonempty `accepted_identity`. That identity
is an exact accepted checkpoint/evidence reference, or a stable named output to
be resolved to that accepted identity before dispatch. A task ID alone is not
checkpoint evidence. The utility checks presence and ownership; the parent still
verifies acceptance and resolves the identity. Extra source inputs require a
nonempty `justification`; they must not silently invent source blockers.

`start_conditions` separately describe actual readiness, including prerequisites
introduced by a chosen Git baseline, shared resources or acceptance aggregation.
Each names a known predecessor task and its kind. A `source` gate must be an
actual source ancestor; every other gate requires a nonempty `justification`
describing its semantic or operational necessity. Preserve genuine safety and
contract requirements. Baseline source contents must be reconciled by the adapter
and parent; this utility does not inspect Git trees or judge justifications.

The readiness graph must be acyclic and reach every required source owner.
Transitive reduction of scheduling edges is allowed: the direct required file
must still remain in `source_inputs` with its own accepted identity even when
its owner is reachable through another predecessor. Successful JSON includes
the mechanically derived direct file/owner sets for comparison with dispatches.
The utility validates a graph; it neither schedules work nor grants dispatch,
merge, acceptance or release permission.

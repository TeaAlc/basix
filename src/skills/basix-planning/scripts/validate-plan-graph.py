#!/usr/bin/env python3
"""Reconcile normalized file dependencies with plan ownership and start conditions."""

import argparse
import json
from pathlib import Path
import hashlib
import sys


KINDS = {"source", "runtime", "schema", "migration", "deployment", "semantic",
         "resource", "acceptance", "baseline"}


class Invalid(ValueError):
    """A controlled input or graph validation failure."""


def require(condition, message):
    """Reject false condition with message; condition is a predicate, message a diagnostic."""
    if not condition:
        raise Invalid(message)


def records(value, label):
    """Check value is an array of objects; label identifies its input location."""
    require(isinstance(value, list) and all(isinstance(x, dict) for x in value),
            f"{label}: expected an array of objects")
    return value


def nonempty(value, label):
    """Check value is a nonempty string; label identifies its input location."""
    require(isinstance(value, str) and bool(value.strip()), f"{label}: expected nonempty string")
    return value


def index(items, label):
    """Index items by unique nonempty ID; label names the collection for errors."""
    result = {}
    for item in records(items, label):
        key = nonempty(item.get("id"), f"{label}.id")
        require(key not in result, f"{label}: duplicate ID {key}")
        result[key] = item
    return result


def ancestors(graph):
    """Return transitive predecessors of graph, a node-to-predecessor-set mapping; reject cycles."""
    done, active = {}, set()

    def visit(node):
        """Resolve node's predecessors; node is a known graph ID."""
        require(node not in active, f"cycle involving {node}")
        if node not in done:
            active.add(node)
            found = set()
            for predecessor in sorted(graph[node]):
                found.add(predecessor)
                found.update(visit(predecessor))
            active.remove(node)
            done[node] = found
        return done[node]

    for node in graph:
        visit(node)
    return done


def validate(inventory, plan):
    """Validate inventory file records against plan task records; return derived graph evidence."""
    require(isinstance(inventory, dict) and isinstance(plan, dict), "inputs must be objects")
    files = index(inventory.get("files"), "files")
    tasks = index(plan.get("tasks"), "tasks")
    require(bool(files) and bool(tasks), "files and tasks must not be empty")
    paths, owner = set(), {}
    for fid, file in files.items():
        path = nonempty(file.get("path"), f"{fid}.path")
        require(path not in paths, f"duplicate path {path}")
        paths.add(path)
        work = nonempty(file.get("work"), f"{fid}.work")
        require(len(work) <= 32, f"{fid}: work exceeds 32 characters")
        for edge in records(file.get("dependencies"), f"{fid}.dependencies"):
            require(edge.get("file") in files, f"{fid}: unknown dependency {edge.get('file')}")
            require(edge.get("kind") in KINDS, f"{fid}: unknown dependency kind")
    for tid, task in tasks.items():
        owned = task.get("files")
        require(isinstance(owned, list) and all(isinstance(x, str) for x in owned),
                f"{tid}.files: expected array of IDs")
        for fid in owned:
            require(fid in files, f"{tid}: unknown file {fid}")
            require(fid not in owner, f"duplicate ownership for {fid}")
            owner[fid] = tid
    require(set(owner) == set(files), f"missing ownership: {sorted(set(files) - set(owner))}")
    needed = {tid: set() for tid in tasks}
    source_graph = {tid: set() for tid in tasks}
    for fid, file in files.items():
        for edge in file.get("dependencies", []):
            target = edge["file"]
            if edge["kind"] == "source" and owner[target] != owner[fid]:
                needed[owner[fid]].add(target)
                source_graph[owner[fid]].add(owner[target])
    source_ancestors = ancestors(source_graph)
    readiness = {tid: set() for tid in tasks}
    input_owners = {tid: set() for tid in tasks}
    for tid, task in tasks.items():
        declared = set()
        for entry in records(task.get("source_inputs", []), f"{tid}.source_inputs"):
            fid = entry.get("file")
            require(isinstance(fid, str) and fid in files, f"{tid}: unknown source input {fid}")
            require(fid not in declared, f"{tid}: duplicate source input {fid}")
            declared.add(fid)
            require(entry.get("owner") == owner[fid], f"{tid}: incorrect source owner for {fid}")
            nonempty(entry.get("accepted_identity"), f"{tid}/{fid}.accepted_identity")
            if owner[fid] != tid:
                input_owners[tid].add(owner[fid])
            if fid not in needed[tid]:
                nonempty(entry.get("justification"), f"{tid}/{fid}: extra source input justification")
        require(needed[tid] <= declared,
                f"{tid}: missing direct cross-owner source inputs {sorted(needed[tid] - declared)}")
        for gate in records(task.get("start_conditions", []), f"{tid}.start_conditions"):
            predecessor, kind = gate.get("task"), gate.get("kind")
            require(isinstance(predecessor, str) and predecessor in tasks,
                    f"{tid}: unknown start-condition task {predecessor}")
            require(kind in KINDS, f"{tid}: unknown start-condition kind")
            require(predecessor not in readiness[tid], f"{tid}: duplicate start condition {predecessor}")
            readiness[tid].add(predecessor)
            if kind == "source":
                require(predecessor in source_ancestors[tid],
                        f"{tid}: invented source blocker {predecessor}; use a justified semantic gate")
            else:
                nonempty(gate.get("justification"), f"{tid}/{predecessor}: gate justification")
    accepted_ancestors = ancestors(readiness)
    for tid in tasks:
        require(input_owners[tid] <= accepted_ancestors[tid],
                f"{tid}: start conditions omit required source owners {sorted(input_owners[tid] - accepted_ancestors[tid])}")
    return {"tasks": len(tasks), "files": len(files),
            "direct_source_inputs": {tid: [{"file": fid, "owner": owner[fid]}
                                          for fid in sorted(needed[tid])] for tid in tasks}}


def load(path):
    """Read JSON from path and return its parsed value and exact-byte SHA-256 identity."""
    raw = Path(path).read_bytes()
    return json.loads(raw), hashlib.sha256(raw).hexdigest()


def main():
    """Parse CLI inputs and emit one JSON evidence object without mutating files."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory")
    parser.add_argument("plan")
    args = parser.parse_args()
    try:
        inventory, inventory_hash = load(args.inventory)
        plan, plan_hash = load(args.plan)
        result = validate(inventory, plan)
        result.update(valid=True, inventory_sha256=inventory_hash, plan_sha256=plan_hash)
    except (Invalid, OSError, ValueError, TypeError, RecursionError) as error:
        print(json.dumps({"valid": False, "error": str(error)}))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())

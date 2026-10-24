#!/usr/bin/env python3
"""Validate normalized opaque whole-plan DAG and a proposed capacity snapshot."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys


class Invalid(ValueError):
    """Controlled input validation failure."""


def require(condition, message):
    """Raise Invalid with message when condition is false."""
    if not condition:
        raise Invalid(message)


def fields(value, names, location):
    """Check value has exactly names as fields; location labels any error."""
    require(isinstance(value, dict) and set(value) == set(names),
            f"{location}: expected exactly {', '.join(names)}")


def array(value, location):
    """Return value as an array; location labels any type error."""
    require(isinstance(value, list), f"{location}: expected array")
    return value


def strings(value, location):
    """Check value contains unique nonempty strings; location labels errors."""
    array(value, location)
    require(all(isinstance(x, str) and x and x == x.strip() for x in value),
            f"{location}: expected nonempty strings")
    require(len(value) == len(set(value)), f"{location}: duplicates")
    return value


def integer(value, location, minimum=0):
    """Return integer value at least minimum; location labels any error."""
    require(type(value) is int and value >= minimum, f"{location}: expected integer >= {minimum}")
    return value


def overlaps(left, right):
    """Return whether normalized paths left and right share ownership scope."""
    return left == right or left.startswith(right + "/") or right.startswith(left + "/")


def validate(data):
    """Validate normalized work-order data and return graph/capacity evidence."""
    fields(data, ("plans", "active"), "work order")
    plans = {}
    for plan in array(data["plans"], "plans"):
        fields(plan, ("id", "depends_on", "writes", "resources"), "plan")
        identity = plan["id"]
        require(isinstance(identity, str) and re.fullmatch(r"[a-z][a-z0-9-]*", identity),
                "plan id: expected lowercase opaque slug")
        require(identity not in plans, "duplicate plan id")
        strings(plan["depends_on"], identity + ".depends_on")
        for path in strings(plan["writes"], identity + ".writes"):
            require(not path.startswith("/") and str(PurePosixPath(path)) == path
                    and ".." not in PurePosixPath(path).parts and "\\" not in path
                    and not any(c in path for c in "*?[]") and path != ".", "writes: expected normalized relative path")
        strings(plan["resources"], identity + ".resources")
        plans[identity] = plan
    require(plans, "plans: must not be empty")
    for identity, plan in plans.items():
        require(all(x in plans for x in plan["depends_on"]), f"{identity}: unknown predecessor plan")
    ancestors = {}
    visiting = set()

    def visit(identity):
        """Return transitive predecessors of plan identity, rejecting cycles."""
        if identity in ancestors:
            return ancestors[identity]
        require(identity not in visiting, "whole-plan cycle")
        visiting.add(identity)
        result = set()
        for predecessor in plans[identity]["depends_on"]:
            result.add(predecessor)
            result.update(visit(predecessor))
        visiting.remove(identity)
        ancestors[identity] = result
        return result

    for identity in plans:
        visit(identity)
    ids = list(plans)
    for offset, left in enumerate(ids):
        for right in ids[offset + 1:]:
            shared = (any(overlaps(a, b) for a in plans[left]["writes"] for b in plans[right]["writes"])
                      or bool(set(plans[left]["resources"]) & set(plans[right]["resources"])))
            require(not shared or left in ancestors[right] or right in ancestors[left],
                    f"{left}/{right}: unordered shared ownership/resource")
    active = data["active"]
    fields(active, ("executors", "root_helpers", "runtime_limit"), "active")
    running = set()
    helpers = integer(active["root_helpers"], "root_helpers")
    executors = array(active["executors"], "executors")
    require(len(executors) <= 3, "capacity: at most three executors")
    for executor in executors:
        fields(executor, ("plan", "helpers"), "executor")
        identity = executor["plan"]
        require(isinstance(identity, str) and identity in plans, "executor: unknown plan")
        require(identity not in running, "executor: duplicate active plan")
        running.add(identity)
        count = integer(executor["helpers"], "executor.helpers")
        require(count <= 2, "capacity: at most two helpers per executor")
        helpers += count
    require(not any(ancestors[x] & running for x in running),
            "active plans include unfinished predecessor")
    require(helpers <= 6, "capacity: at most six read-only helpers")
    descendants = len(executors) + helpers
    require(descendants <= 9, "capacity: at most nine descendants")
    runtime = integer(active["runtime_limit"], "runtime_limit", 1)
    require(descendants + 1 <= runtime, "capacity: runtime limit includes Root")
    return {"valid": True, "predecessors": {x: sorted(ancestors[x]) for x in plans},
            "active_descendants": descendants}


def main():
    """Read the CLI input and emit JSON validation evidence or a controlled error."""
    try:
        require(len(sys.argv) == 2, "usage: validate-work-order.py work-order.json")
        raw = Path(sys.argv[1]).read_bytes()
        def unique(pairs):
            """Build a JSON object from pairs, rejecting duplicate keys."""
            result = {}
            for key, value in pairs:
                require(key not in result, "duplicate JSON key")
                result[key] = value
            return result
        result = validate(json.loads(raw, object_pairs_hook=unique))
        result["input_sha256"] = hashlib.sha256(raw).hexdigest()
    except (Invalid, OSError, ValueError, RecursionError) as error:
        print(json.dumps({"valid": False, "error": str(error)}))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())

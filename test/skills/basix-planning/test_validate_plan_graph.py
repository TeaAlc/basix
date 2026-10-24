"""Behavioral checks for normalized planning dependency reconciliation."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[3] / "src/skills/basix-planning/scripts/validate-plan-graph.py"
SPEC = importlib.util.spec_from_file_location("plan_graph", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def fixture():
    """Return an independent three-task source chain with an additional direct edge."""
    inventory = {"files": [
        {"id": "a", "path": "a.py", "work": "Define", "dependencies": []},
        {"id": "b", "path": "b.py", "work": "Build", "dependencies": [{"file": "a", "kind": "source"}]},
        {"id": "c", "path": "c.py", "work": "Consume", "dependencies": [
            {"file": "a", "kind": "source"}, {"file": "b", "kind": "source"}]},
    ]}
    plan = {"tasks": []}
    for tid, inputs, predecessor in [("a", [], None), ("b", ["a"], "a"), ("c", ["a", "b"], "b")]:
        plan["tasks"].append({"id": tid, "files": [tid],
                              "source_inputs": [{"file": fid, "owner": fid,
                                                 "accepted_identity": f"accepted:{fid}/checkpoint"} for fid in inputs],
                              "start_conditions": ([{"task": predecessor, "kind": "source"}] if predecessor else [])})
    return inventory, plan


class ValidateGraphTests(unittest.TestCase):
    """Validate graph semantics independently from textual skill wording."""

    def test_transitive_schedule_retains_direct_source_input(self):
        """Check a reduced chain exposes direct inputs; self is the test case."""
        inventory, plan = fixture()
        result = MODULE.validate(inventory, plan)
        self.assertEqual(result["direct_source_inputs"]["c"],
                         [{"file": "a", "owner": "a"}, {"file": "b", "owner": "b"}])
        plan["tasks"][2]["source_inputs"].pop(0)
        with self.assertRaisesRegex(MODULE.Invalid, "missing direct cross-owner source inputs"):
            MODULE.validate(inventory, plan)

    def test_unique_complete_ownership(self):
        """Reject duplicate and missing ownership; self is the test case."""
        inventory, plan = fixture()
        for owned, expected in [(["a", "b"], "duplicate ownership"), ([], "missing ownership")]:
            changed = copy.deepcopy(plan)
            changed["tasks"][1]["files"] = owned
            with self.assertRaisesRegex(MODULE.Invalid, expected):
                MODULE.validate(inventory, changed)

    def test_unknown_references(self):
        """Reject unknown file/task references; self is the test case."""
        inventory, plan = fixture()
        inventory["files"][1]["dependencies"][0]["file"] = "unknown"
        with self.assertRaisesRegex(MODULE.Invalid, "unknown dependency"):
            MODULE.validate(inventory, plan)
        inventory, plan = fixture()
        plan["tasks"][1]["start_conditions"][0]["task"] = "unknown"
        with self.assertRaisesRegex(MODULE.Invalid, "unknown start-condition"):
            MODULE.validate(inventory, plan)

    def test_readiness_cycle(self):
        """Reject a gate that cycles readiness; self is the test case."""
        inventory, plan = fixture()
        plan["tasks"][0]["start_conditions"] = [{"task": "c", "kind": "resource", "justification": "Shared fixture"}]
        with self.assertRaisesRegex(MODULE.Invalid, "cycle"):
            MODULE.validate(inventory, plan)

    def test_typed_edges_allow_parallel_implementation(self):
        """Check runtime edges impose no source blockers; self is the test case."""
        inventory, plan = fixture()
        for file in inventory["files"]:
            for edge in file["dependencies"]:
                edge["kind"] = "runtime"
        for task in plan["tasks"]:
            task["source_inputs"] = []
            task["start_conditions"] = []
        self.assertTrue(MODULE.validate(inventory, plan))
        plan["tasks"][1]["start_conditions"] = [{"task": "a", "kind": "source"}]
        with self.assertRaisesRegex(MODULE.Invalid, "invented source blocker"):
            MODULE.validate(inventory, plan)
        plan["tasks"][1]["start_conditions"] = [{"task": "a", "kind": "runtime", "justification": "Exercise live transport"}]
        self.assertTrue(MODULE.validate(inventory, plan))

    def test_identity_and_extra_gate_require_evidence(self):
        """Reject missing identities and justifications; self is the test case."""
        inventory, plan = fixture()
        del plan["tasks"][1]["source_inputs"][0]["accepted_identity"]
        with self.assertRaisesRegex(MODULE.Invalid, "accepted_identity"):
            MODULE.validate(inventory, plan)
        inventory, plan = fixture()
        plan["tasks"][2]["start_conditions"][0]["kind"] = "baseline"
        with self.assertRaisesRegex(MODULE.Invalid, "gate justification"):
            MODULE.validate(inventory, plan)

    def test_inventory_identity_and_task_ids(self):
        """Reject duplicate IDs/paths and long work; self is the test case."""
        inventory, plan = fixture()
        variants = []
        duplicate_id = copy.deepcopy(inventory)
        duplicate_id["files"][1]["id"] = "a"
        variants.append((duplicate_id, plan, "duplicate ID"))
        duplicate_path = copy.deepcopy(inventory)
        duplicate_path["files"][1]["path"] = "a.py"
        variants.append((duplicate_path, plan, "duplicate path"))
        long_work = copy.deepcopy(inventory)
        long_work["files"][1]["work"] = "x" * 33
        variants.append((long_work, plan, "work exceeds"))
        duplicate_task = copy.deepcopy(plan)
        duplicate_task["tasks"][1]["id"] = "a"
        variants.append((inventory, duplicate_task, "duplicate ID"))
        for source, proposed, expected in variants:
            with self.subTest(expected=expected):
                with self.assertRaisesRegex(MODULE.Invalid, expected):
                    MODULE.validate(source, proposed)

    def test_missing_readiness(self):
        """Reject a declared source input without readiness; self is the test case."""
        inventory, plan = fixture()
        plan["tasks"][2]["start_conditions"] = []
        with self.assertRaisesRegex(MODULE.Invalid, "start conditions omit required source owners"):
            MODULE.validate(inventory, plan)

    def test_requires_explicit_normalized_dependencies(self):
        """Reject unnormalized dependency metadata; self is the test case."""
        inventory, plan = fixture()
        inventory["files"][1]["upstream_metadata"] = inventory["files"][1].pop("dependencies")
        with self.assertRaisesRegex(MODULE.Invalid, "b.dependencies: expected an array"):
            MODULE.validate(inventory, plan)
        inventory, plan = fixture()
        inventory["files"][0]["adapter_provenance"] = {"original_id": "original-a"}
        self.assertTrue(MODULE.validate(inventory, plan))

    def test_cli_evidence_and_controlled_error(self):
        """Check CLI identities and malformed JSON handling; self is the test case."""
        inventory, plan = fixture()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "inventory.json"
            proposed = Path(directory) / "plan.json"
            source.write_text(json.dumps(inventory))
            proposed.write_text(json.dumps(plan))
            result = subprocess.run([sys.executable, str(SCRIPT), str(source), str(proposed)],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            evidence = json.loads(result.stdout)
            self.assertTrue(evidence["valid"])
            self.assertEqual(len(evidence["inventory_sha256"]), 64)
            self.assertEqual(len(evidence["plan_sha256"]), 64)
            source.write_text("{")
            result = subprocess.run([sys.executable, str(SCRIPT), str(source), str(proposed)],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertFalse(json.loads(result.stdout)["valid"])
            self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()

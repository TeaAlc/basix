"""Behavioral coverage of the whole-plan graph, ownership and capacity contract."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[3] / "src/skills/basix-planning/scripts/validate-work-order.py"
SPEC = importlib.util.spec_from_file_location("work_order", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def fixture():
    """Return a valid independent-plan snapshot with a whole-plan predecessor."""
    return {"plans": [
        {"id": "api", "depends_on": [], "writes": ["src/api.py"], "resources": []},
        {"id": "ui", "depends_on": ["api"], "writes": ["src/ui.py"], "resources": []},
        {"id": "docs", "depends_on": [], "writes": ["docs"], "resources": []},
    ], "active": {"executors": [{"plan": "ui", "helpers": 2}, {"plan": "docs", "helpers": 0}],
                  "root_helpers": 1, "runtime_limit": 10}}


class WorkOrderTests(unittest.TestCase):
    def reject(self, data, message):
        """Use test case self to assert data fails with error pattern message."""
        with self.assertRaisesRegex(MODULE.Invalid, message):
            MODULE.validate(data)

    def test_join_and_unknown_reference_and_cycle(self):
        """Use test case self to check joins, unknown predecessors and cycles."""
        data = fixture()
        data["plans"][1]["depends_on"].append("docs")
        data["active"]["executors"].pop()
        self.assertEqual(MODULE.validate(data)["predecessors"]["ui"], ["api", "docs"])
        data["plans"][0]["depends_on"] = ["ui"]
        self.reject(data, "cycle")
        data = fixture()
        data["plans"][1]["depends_on"] = ["missing"]
        self.reject(data, "unknown predecessor")

    def test_opaque_edges_and_strict_fields(self):
        """Use test case self to reject internal selectors and unknown fields."""
        for edge in (["api/phase-1"], [{"plan": "api", "phase": 1}], ["api#task-1"]):
            data = fixture()
            data["plans"][1]["depends_on"] = edge
            self.reject(data, "unknown predecessor|expected nonempty strings")
        for location in ("root", "plan", "snapshot", "executor"):
            data = fixture()
            target = {"root": data, "plan": data["plans"][0], "snapshot": data["active"],
                      "executor": data["active"]["executors"][0]}[location]
            target["phases"] = []
            self.reject(data, "expected exactly")

    def test_shared_paths_and_resources_require_serial_predecessor(self):
        """Use test case self to check serial shared ownership and active conflicts."""
        for writes, resources in ((["src/api.py"], []), (["src"], []), ([], ["database"])):
            data = fixture()
            data["plans"][1]["writes"] = ["frontend/ui.py"]
            data["plans"][0]["resources"] = ["database"]
            data["plans"][2]["writes"] = writes
            data["plans"][2]["resources"] = resources
            self.reject(data, "unordered shared")
            data["plans"][2]["depends_on"] = ["api"]
            self.assertTrue(MODULE.validate(data)["valid"])
            data["active"]["executors"][0]["plan"] = "api"
            self.reject(data, "unfinished predecessor")

    def test_transitive_ownership_transfer(self):
        """Use test case self to accept shared ownership through transitive order."""
        data = fixture()
        data["plans"][2]["depends_on"] = ["ui"]
        data["plans"][2]["writes"] = ["src/api.py"]
        data["active"]["executors"] = [{"plan": "docs", "helpers": 0}]
        self.assertTrue(MODULE.validate(data)["valid"])

    def test_capacity_and_runtime_harder_cap(self):
        """Use test case self to reject helper, executor and runtime excess."""
        data = fixture()
        data["active"]["runtime_limit"] = 4
        self.reject(data, "runtime limit")
        data["active"]["runtime_limit"] = 10
        data["active"]["executors"][0]["helpers"] = 3
        self.reject(data, "two helpers")
        data["active"]["executors"][0]["helpers"] = 2
        data["active"]["root_helpers"] = 5
        self.reject(data, "six read-only")
        data = fixture()
        data["active"]["executors"] *= 2
        self.reject(data, "three executors")
        data["active"]["executors"] = [{"plan": "docs", "helpers": True}]
        self.reject(data, "expected integer")

    def test_maximum_requested_capacity_and_zero_snapshot(self):
        """Use test case self to accept maximum and empty capacity snapshots."""
        data = fixture()
        for plan in data["plans"]:
            plan["depends_on"] = []
        data["active"]["executors"] = [{"plan": p["id"], "helpers": 2} for p in data["plans"]]
        data["active"]["root_helpers"] = 0
        self.assertEqual(MODULE.validate(data)["active_descendants"], 9)
        data["active"]["executors"] = []
        data["active"]["runtime_limit"] = 1
        self.assertEqual(MODULE.validate(data)["active_descendants"], 0)

    def test_normalized_paths_unique_ids_and_snapshot(self):
        """Use test case self to reject malformed paths and invalid identities."""
        for path in ("../x", "/x", "src//x", "src/./x", "src/*", "src\\x", "."):
            data = fixture()
            data["plans"][0]["writes"] = [path]
            self.reject(data, "normalized relative path")
        data = fixture()
        data["plans"][0]["id"] = "ui"
        self.reject(data, "duplicate plan")
        data = fixture()
        data["active"]["executors"] *= 1
        data["active"]["executors"][1]["plan"] = "ui"
        self.reject(data, "duplicate active")
        data["active"]["executors"][1]["plan"] = "missing"
        self.reject(data, "unknown plan")

    def test_cli_hash_and_controlled_failures(self):
        """Use test case self to check CLI evidence and controlled JSON failures."""
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "order.json"
            for raw, code in ((json.dumps(fixture()), 0), ("{", 1), ('{"plans":[],"plans":[]}', 1)):
                source.write_text(raw)
                run = subprocess.run([sys.executable, str(SCRIPT), str(source)], capture_output=True, text=True)
                self.assertEqual(run.returncode, code, run.stdout + run.stderr)
                self.assertEqual(run.stderr, "")
                result = json.loads(run.stdout)
                self.assertEqual(result["valid"], code == 0)
                if code == 0:
                    self.assertEqual(len(result["input_sha256"]), 64)


if __name__ == "__main__":
    unittest.main()

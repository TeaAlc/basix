"""Deterministic read-only verifier fixtures.

The native verifier is prompt-driven, so this smoke test models its non-negotiable
decision boundary: immutable fingerprints, evidence gaps, and bounded findings.
The simulated verifier never writes the target after the fixture is created.
"""

import hashlib
import tempfile
import unittest
from pathlib import Path


def fingerprint(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(path: Path, expected: bytes, evidence: bool, mutate=None) -> dict:
    before = fingerprint(path)
    observed = path.read_bytes()
    if mutate is not None:
        mutate(path)
    after = fingerprint(path)
    if before != after:
        return {"verdict": "inconclusive", "reason": "target drift"}
    if not evidence:
        return {"verdict": "inconclusive", "reason": "evidence gap"}
    if observed != expected:
        return {
            "verdict": "remediation_required",
            "findings": [{"id": "V-001", "status": "confirmed"}],
        }
    return {"verdict": "pass", "findings": []}


class VerifierSmokeTests(unittest.TestCase):
    def test_passing_result_is_evidence_backed_and_read_only(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "result.txt"
            target.write_bytes(b"accepted\n")
            before = fingerprint(target)
            report = verify(target, b"accepted\n", evidence=True)
            self.assertEqual(report["verdict"], "pass")
            self.assertEqual(before, fingerprint(target))

    def test_confirmed_defect_has_actionable_finding(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "result.txt"
            target.write_bytes(b"wrong\n")
            report = verify(target, b"accepted\n", evidence=True)
            self.assertEqual(report["verdict"], "remediation_required")
            self.assertEqual(report["findings"][0]["status"], "confirmed")

    def test_missing_evidence_is_inconclusive(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "result.txt"
            target.write_bytes(b"accepted\n")
            report = verify(target, b"accepted\n", evidence=False)
            self.assertEqual(report["verdict"], "inconclusive")
            self.assertEqual(report["reason"], "evidence gap")

    def test_concurrent_target_mutation_is_inconclusive(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "result.txt"
            target.write_bytes(b"accepted\n")
            report = verify(target, b"accepted\n", evidence=True,
                            mutate=lambda path: path.write_bytes(b"drifted\n"))
            self.assertEqual(report["verdict"], "inconclusive")
            self.assertEqual(report["reason"], "target drift")


if __name__ == "__main__":
    unittest.main()

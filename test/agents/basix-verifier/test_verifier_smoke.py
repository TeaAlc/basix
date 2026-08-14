"""Deterministic verifier lifecycle fixtures.

The native verifier is prompt-driven, so this smoke test models the parent's
non-negotiable write-freeze boundary and bounded evidence verdicts.
"""

import unittest


INACTIVE = {"completed", "completed_with_errors", "failed", "stopped"}


def overlaps(writer_targets, owned_targets):
    if writer_targets is None or "*" in writer_targets:
        return True
    return bool(set(writer_targets) & set(owned_targets))


def may_spawn_verifier(writers, owned_targets):
    return all(
        writer["status"] in INACTIVE
        or not overlaps(writer.get("targets"), owned_targets)
        for writer in writers
    )


class VerificationRun:
    def __init__(self, owned_targets):
        self.owned_targets = owned_targets
        self.active = True
        self.result_discarded = False

    def may_follow_up(self, writer_targets):
        return not self.active or not overlaps(writer_targets, self.owned_targets)

    def reopen_for_write(self):
        self.active = False
        self.result_discarded = True


def verify(observed, expected, evidence):
    if not evidence:
        return {"verdict": "inconclusive", "reason": "evidence gap"}
    if observed != expected:
        return {
            "verdict": "remediation_required",
            "findings": [{"id": "V-001", "status": "confirmed"}],
        }
    return {"verdict": "pass", "findings": []}


class VerifierSmokeTests(unittest.TestCase):
    def test_active_overlapping_writer_blocks_spawn(self):
        writers = [{"status": "in_progress", "targets": {"src/result.txt"}}]
        self.assertFalse(may_spawn_verifier(writers, {"src/result.txt"}))

    def test_unknown_or_broad_ownership_blocks_fail_closed(self):
        for targets in (None, {"*"}):
            with self.subTest(targets=targets):
                writers = [{"status": "in_progress", "targets": targets}]
                self.assertFalse(may_spawn_verifier(writers, {"src/result.txt"}))

    def test_terminal_or_stopped_writer_is_inactive(self):
        for status in INACTIVE:
            with self.subTest(status=status):
                writers = [{"status": status, "targets": {"src/result.txt"}}]
                self.assertTrue(may_spawn_verifier(writers, {"src/result.txt"}))

    def test_active_disjoint_writer_does_not_block(self):
        writers = [{"status": "in_progress", "targets": {"docs/other.md"}}]
        self.assertTrue(may_spawn_verifier(writers, {"src/result.txt"}))

    def test_relevant_followup_is_forbidden_during_verification(self):
        run = VerificationRun({"src/result.txt"})
        self.assertFalse(run.may_follow_up({"src/result.txt"}))
        self.assertTrue(run.may_follow_up({"docs/other.md"}))

    def test_reopening_writes_discards_run_and_requires_fresh_verifier(self):
        run = VerificationRun({"src/result.txt"})
        run.reopen_for_write()
        self.assertFalse(run.active)
        self.assertTrue(run.result_discarded)
        fresh_run = VerificationRun({"src/result.txt"})
        self.assertIsNot(run, fresh_run)
        self.assertTrue(fresh_run.active)

    def test_evidence_verdicts_remain_bounded(self):
        self.assertEqual(verify(b"accepted", b"accepted", True)["verdict"], "pass")
        defect = verify(b"wrong", b"accepted", True)
        self.assertEqual(defect["verdict"], "remediation_required")
        self.assertEqual(defect["findings"][0]["id"], "V-001")
        self.assertEqual(verify(b"accepted", b"accepted", False)["verdict"], "inconclusive")


if __name__ == "__main__":
    unittest.main()

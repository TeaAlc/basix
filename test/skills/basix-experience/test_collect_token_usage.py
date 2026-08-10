#!/usr/bin/env python3
"""Isolated integration tests for the basix-experience token collector."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3] / "src"
COLLECTOR = ROOT / "skills" / "basix-experience" / "scripts" / "collect-token-usage.py"
ROOT_ID = "11111111-1111-4111-8111-111111111111"
CHILD_ID = "22222222-2222-4222-8222-222222222222"
GRANDCHILD_ID = "33333333-3333-4333-8333-333333333333"
OTHER_ID = "44444444-4444-4444-8444-444444444444"
CUTOFF = "2026-08-10T12:00:00+00:00"


def event(timestamp: str, payload: dict[str, object], event_type: str = "event_msg") -> dict[str, object]:
    return {"timestamp": timestamp, "type": event_type, "payload": payload}


def token_event(
    timestamp: str,
    *,
    input_tokens: object = 100,
    cached_input_tokens: object = 25,
    cache_write_input_tokens: object = 5,
    output_tokens: object = 40,
    reasoning_output_tokens: object = 10,
    total_tokens: object = 140,
    context_window: object = 200_000,
) -> dict[str, object]:
    totals = {
        "input_tokens": input_tokens,
        "cached_input_tokens": cached_input_tokens,
        "cache_write_input_tokens": cache_write_input_tokens,
        "output_tokens": output_tokens,
        "reasoning_output_tokens": reasoning_output_tokens,
        "total_tokens": total_tokens,
    }
    info: dict[str, object] = {"total_token_usage": totals}
    if context_window != "OMIT":
        info["model_context_window"] = context_window
    return event(timestamp, {"type": "token_count", "info": info})


def started(timestamp: str, thread_id: str, agent_path: str) -> dict[str, object]:
    return event(
        timestamp,
        {
            "type": "sub_agent_activity",
            "kind": "started",
            "agent_thread_id": thread_id,
            "agent_path": agent_path,
        },
    )


class CollectorCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="basix-token-tests-")
        self.sessions = Path(self.temp.name) / "sessions"
        self.sessions.mkdir()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def rollout_path(self, thread_id: str, stamp: str = "2026-08-10T10-00-00", branch: str = "a") -> Path:
        directory = self.sessions / branch
        directory.mkdir(parents=True, exist_ok=True)
        return directory / f"rollout-{stamp}-{thread_id}.jsonl"

    def write_rollout(
        self,
        thread_id: str,
        records: list[dict[str, object]],
        *,
        trailing: bytes = b"",
        stamp: str = "2026-08-10T10-00-00",
        branch: str = "a",
    ) -> Path:
        path = self.rollout_path(thread_id, stamp, branch)
        with path.open("wb") as handle:
            for record in records:
                handle.write(json.dumps(record, separators=(",", ":")).encode() + b"\n")
            handle.write(trailing)
        return path

    def run_collector(
        self,
        *extra: str,
        thread_id: str = ROOT_ID,
        sessions: Path | None = None,
        cutoff: str | None = CUTOFF,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(COLLECTOR),
            "--thread-id",
            thread_id,
            "--sessions-dir",
            str(sessions or self.sessions),
        ]
        if cutoff is not None:
            command += ["--cutoff", cutoff]
        command += list(extra)
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return subprocess.run(command, text=True, capture_output=True, env=environment, check=False)

    def run_json(self, *extra: str, **kwargs: object) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
        result = self.run_collector(*extra, **kwargs)
        return result, json.loads(result.stdout)

    def test_root_uses_latest_cumulative_totals_without_reasoning_double_count(self) -> None:
        self.write_rollout(
            ROOT_ID,
            [
                token_event("2026-08-10T10:00:00Z", total_tokens=90),
                token_event(
                    "2026-08-10T11:00:00Z",
                    input_tokens=120,
                    cached_input_tokens=30,
                    cache_write_input_tokens=6,
                    output_tokens=50,
                    reasoning_output_tokens=12,
                    total_tokens=170,
                    context_window=250_000,
                ),
            ],
        )
        result, document = self.run_json()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(document["status"], "ok")
        self.assertEqual(document["threads"][0]["role"], "root")
        self.assertEqual(document["threads"][0]["model_context_window"], 250_000)
        self.assertEqual(document["aggregate"]["total_tokens"], 170)
        self.assertEqual(document["aggregate"]["reasoning_output_tokens"], 12)
        self.assertEqual(document["aggregate"]["cache_hit_rate_percent"], 25.0)

    def test_nested_agents_deduplicate_cycles_and_respect_cutoff_and_file_order(self) -> None:
        self.write_rollout(
            ROOT_ID,
            [
                token_event("2026-08-10T10:00:00Z", input_tokens=10, total_tokens=20),
                token_event("2026-08-10T10:00:00Z", input_tokens=20, total_tokens=30),
                started("2026-08-10T10:01:00Z", CHILD_ID, "/root/child"),
                started("2026-08-10T10:02:00Z", CHILD_ID, "/root/child"),
                token_event("2026-08-10T13:00:00Z", input_tokens=999, total_tokens=999),
                started("2026-08-10T13:00:00Z", OTHER_ID, "/root/too-late"),
            ],
        )
        self.write_rollout(
            CHILD_ID,
            [
                token_event("2026-08-10T10:03:00Z", input_tokens=30, total_tokens=50),
                started("2026-08-10T10:04:00Z", GRANDCHILD_ID, "/root/child/grandchild"),
            ],
            branch="b",
        )
        self.write_rollout(
            GRANDCHILD_ID,
            [
                token_event("2026-08-10T10:05:00Z", input_tokens=40, total_tokens=60),
                started("2026-08-10T10:06:00Z", ROOT_ID, "/root"),
            ],
            branch="c",
        )
        result, document = self.run_json()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [thread["thread_id"] for thread in document["threads"]],
            [ROOT_ID, CHILD_ID, GRANDCHILD_ID],
        )
        self.assertEqual([thread["role"] for thread in document["threads"]], ["root", "subagent", "subagent"])
        self.assertEqual(document["threads"][0]["input_tokens"], 20)
        self.assertEqual(document["aggregate"]["input_tokens"], 90)
        self.assertEqual(document["aggregate"]["total_tokens"], 140)

    def test_conflicting_agent_paths_are_ambiguous(self) -> None:
        self.write_rollout(
            ROOT_ID,
            [
                token_event("2026-08-10T10:00:00Z"),
                started("2026-08-10T10:01:00Z", CHILD_ID, "/root/one"),
                started("2026-08-10T10:02:00Z", CHILD_ID, "/root/two"),
            ],
        )
        self.write_rollout(CHILD_ID, [token_event("2026-08-10T10:03:00Z")], branch="b")
        result, document = self.run_json()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(document["status"], "error")
        self.assertIn("AGENT_PATH_CONFLICT", document["warnings"])
        self.assertEqual(len(document["threads"]), 2)

    def test_conflicting_path_on_visited_cycle_is_an_error(self) -> None:
        self.write_rollout(
            ROOT_ID,
            [
                token_event("2026-08-10T10:00:00Z"),
                started("2026-08-10T10:01:00Z", CHILD_ID, "/root/child"),
            ],
        )
        self.write_rollout(
            CHILD_ID,
            [
                token_event("2026-08-10T10:02:00Z"),
                started("2026-08-10T10:03:00Z", ROOT_ID, "/wrong-root"),
            ],
            branch="b",
        )
        result, document = self.run_json()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(document["status"], "error")
        self.assertIn("AGENT_PATH_CONFLICT", document["warnings"])
        self.assertEqual(len(document["threads"]), 2)

    def test_missing_child_is_partial_without_blocking_independent_child(self) -> None:
        self.write_rollout(
            ROOT_ID,
            [
                token_event("2026-08-10T10:00:00Z"),
                started("2026-08-10T10:01:00Z", CHILD_ID, "/root/missing"),
                started("2026-08-10T10:02:00Z", OTHER_ID, "/root/available"),
            ],
        )
        self.write_rollout(OTHER_ID, [token_event("2026-08-10T10:03:00Z", input_tokens=7)], branch="b")
        result, document = self.run_json()
        self.assertEqual(result.returncode, 1)
        available = next(thread for thread in document["threads"] if thread["thread_id"] == OTHER_ID)
        self.assertEqual(available["input_tokens"], 7)
        self.assertIsNone(document["aggregate"]["input_tokens"])
        self.assertIn("ROLLOUT_NOT_FOUND", document["warnings"])

    def test_ambiguous_symlink_and_nonregular_rollouts_are_errors(self) -> None:
        cases = ("ambiguous", "symlink", "fifo")
        for case in cases:
            with self.subTest(case=case):
                local = self.sessions / case
                local.mkdir()
                primary = local / f"rollout-2026-08-10T10-00-00-{ROOT_ID}.jsonl"
                if case == "ambiguous":
                    primary.write_text(json.dumps(token_event("2026-08-10T10:00:00Z")) + "\n")
                    duplicate_dir = local / "duplicate"
                    duplicate_dir.mkdir()
                    (duplicate_dir / f"rollout-2026-08-10T10-00-01-{ROOT_ID}.jsonl").write_text(
                        json.dumps(token_event("2026-08-10T10:00:00Z")) + "\n"
                    )
                    expected = "ROLLOUT_AMBIGUOUS"
                elif case == "symlink":
                    target = local / "target"
                    target.write_text("ignored")
                    primary.symlink_to(target)
                    expected = "ROLLOUT_SYMLINK"
                else:
                    os.mkfifo(primary)
                    expected = "ROLLOUT_NOT_REGULAR"
                result, document = self.run_json(sessions=local)
                self.assertEqual(result.returncode, 2)
                self.assertIn(expected, document["warnings"])

    def test_complete_malformed_line_is_error_but_trailing_fragment_is_partial_and_sanitized(self) -> None:
        secret = "SUPER_SECRET_MESSAGE"
        session_path = str(self.sessions)
        self.write_rollout(
            ROOT_ID,
            [token_event("2026-08-10T10:00:00Z")],
            trailing=(f'{{"secret":"{secret}"}} BROKEN\n').encode(),
        )
        result, document = self.run_json()
        self.assertEqual(result.returncode, 2)
        self.assertIn("MALFORMED_JSONL", document["warnings"])
        self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertNotIn(session_path, result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stdout + result.stderr)

        self.sessions = Path(self.temp.name) / "fragment-sessions"
        self.sessions.mkdir()
        self.write_rollout(
            ROOT_ID,
            [
                event("2026-08-10T10:00:00Z", {"type": "message", "message": secret}),
                token_event("2026-08-10T10:01:00Z"),
            ],
            trailing=f'{{"secret":"{secret}"'.encode(),
        )
        result, document = self.run_json()
        self.assertEqual(result.returncode, 1)
        self.assertIn("TRAILING_JSON_FRAGMENT", document["warnings"])
        self.assertNotIn(secret, result.stdout + result.stderr)

    def test_null_missing_context_and_zero_input_remain_partial_not_zero_filled(self) -> None:
        self.write_rollout(
            ROOT_ID,
            [
                token_event(
                    "2026-08-10T10:00:00Z",
                    input_tokens=0,
                    cached_input_tokens=0,
                    cache_write_input_tokens=None,
                    output_tokens=0,
                    reasoning_output_tokens=None,
                    total_tokens=0,
                    context_window="OMIT",
                )
            ],
        )
        result, document = self.run_json()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(document["aggregate"]["input_tokens"], 0)
        self.assertEqual(document["aggregate"]["output_tokens"], 0)
        self.assertIsNone(document["aggregate"]["reasoning_output_tokens"])
        self.assertIsNone(document["aggregate"]["cache_write_input_tokens"])
        self.assertIsNone(document["aggregate"]["cache_hit_rate_percent"])
        self.assertIsNone(document["threads"][0]["model_context_window"])

    def test_invalid_metric_type_is_error_and_previous_valid_state_survives(self) -> None:
        self.write_rollout(
            ROOT_ID,
            [
                token_event("2026-08-10T10:00:00Z", input_tokens=11),
                token_event("2026-08-10T11:00:00Z", input_tokens="11"),
            ],
        )
        result, document = self.run_json()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(document["threads"][0]["input_tokens"], 11)
        self.assertIn("INVALID_TOKEN_VALUE", document["warnings"])

    def test_missing_token_event_and_unreadable_root_are_classified(self) -> None:
        self.write_rollout(
            ROOT_ID,
            [event("2026-08-10T10:00:00Z", {"type": "message", "message": "ignored"})],
        )
        result, document = self.run_json()
        self.assertEqual(result.returncode, 1)
        self.assertIn("TOKEN_EVENT_MISSING", document["warnings"])

        non_directory = Path(self.temp.name) / "not-a-directory"
        non_directory.write_text("private path contents")
        result, document = self.run_json(sessions=non_directory)
        self.assertEqual(result.returncode, 2)
        self.assertIn("DIRECTORY_UNREADABLE", document["warnings"])
        self.assertNotIn(str(non_directory), result.stdout + result.stderr)

    def test_json_and_text_output_are_stable_and_sanitized(self) -> None:
        self.write_rollout(ROOT_ID, [token_event("2026-08-10T10:00:00Z")])
        first, first_doc = self.run_json()
        second, second_doc = self.run_json()
        self.assertEqual(first.returncode, second.returncode, 0)
        first_doc.pop("snapshot_at")
        second_doc.pop("snapshot_at")
        self.assertEqual(first_doc, second_doc)
        text_result = self.run_collector("--format", "text")
        self.assertEqual(text_result.returncode, 0)
        self.assertIn("status: ok\n", text_result.stdout)
        self.assertIn("cache_hit_rate_percent: 25.0\n", text_result.stdout)
        self.assertNotIn(str(self.sessions), text_result.stdout + text_result.stderr)

    def test_invalid_invocations_return_usage_code_without_echoing_values(self) -> None:
        cases = [
            ["--thread-id", "not-a-secret-valid-uuid"],
            ["--thread-id", ROOT_ID, "--cutoff", "2026-08-10T12:00:00"],
            ["--thread-id", ROOT_ID, "--format", "secret-format"],
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                environment = os.environ.copy()
                environment["PYTHONDONTWRITEBYTECODE"] = "1"
                result = subprocess.run(
                    [sys.executable, str(COLLECTOR), *arguments],
                    text=True,
                    capture_output=True,
                    env=environment,
                    check=False,
                )
                self.assertEqual(result.returncode, 64)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "error: invalid invocation\n")

    def test_invalid_activity_and_timestamp_are_errors(self) -> None:
        self.write_rollout(
            ROOT_ID,
            [
                token_event("not-a-time"),
                event(
                    "2026-08-10T10:00:00Z",
                    {
                        "type": "sub_agent_activity",
                        "kind": "started",
                        "agent_thread_id": CHILD_ID,
                        "agent_path": None,
                    },
                ),
            ],
        )
        result, document = self.run_json()
        self.assertEqual(result.returncode, 2)
        self.assertIn("INVALID_EVENT_TIMESTAMP", document["warnings"])
        self.assertIn("INVALID_SUB_AGENT_ACTIVITY", document["warnings"])


if __name__ == "__main__":
    unittest.main(verbosity=2)

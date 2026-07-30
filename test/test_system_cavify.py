import contextlib
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import system_cavify


class FakeRunner:
    def __init__(self, responses=None):
        self.responses = iter(responses or [])
        self.calls = []

    def execute(self, prompt, schema):
        self.calls.append((prompt, schema))
        if schema is system_cavify.SKILL_SCHEMA:
            return {"skill": "caveman", "available": True, "loaded": True}
        return {"compressed": next(self.responses)}


class CavifyTests(unittest.TestCase):
    def test_skill_schema_const_has_explicit_api_required_type(self):
        self.assertEqual(
            system_cavify.SKILL_SCHEMA["properties"]["skill"],
            {"type": "string", "const": "caveman"},
        )

    def test_nested_targets_are_replaced_and_duplicates_are_deduplicated(self):
        source = {
            "z": 7,
            "instructions_template": "same",
            "nested": [
                {"personality_default": "same", "keep": "same"},
                {"items": [{"base_instructions": "different"}]},
            ],
        }
        runner = FakeRunner(["short same", "short different"])
        result = system_cavify.cavify(source, runner)
        self.assertEqual(result["instructions_template"], "short same")
        self.assertEqual(result["nested"][0]["personality_default"], "short same")
        self.assertEqual(result["nested"][1]["items"][0]["base_instructions"], "short different")
        self.assertEqual(result["nested"][0]["keep"], "same")
        self.assertEqual(len(runner.calls), 3)  # verification plus two unique texts
        self.assertEqual(list(result), list(source))
        self.assertEqual(source["instructions_template"], "same")

    def test_empty_target_is_unchanged_and_not_compressed(self):
        runner = FakeRunner()
        source = {
            "personality_friendly": "",
            "nested": {"personality_default": None},
            "other": [1, True, None],
        }
        self.assertEqual(system_cavify.cavify(source, runner), source)
        self.assertEqual(len(runner.calls), 1)

    def test_non_string_target_is_rejected_before_codex(self):
        runner = FakeRunner()
        with self.assertRaisesRegex(system_cavify.CavifyError, "must be a string or null"):
            system_cavify.cavify({"x": [{"base_instructions": 3}]}, runner)
        self.assertEqual(runner.calls, [])

    def test_missing_skill_is_rejected(self):
        runner = FakeRunner()
        runner.execute = mock.Mock(return_value={"skill": "caveman", "available": False, "loaded": False})
        with self.assertRaisesRegex(system_cavify.CavifyError, "unavailable"):
            system_cavify.cavify({"base_instructions": "x"}, runner)

    def test_invalid_compression_responses_are_rejected(self):
        for response in ({}, {"compressed": 4}, {"compressed": "x", "extra": 1}, []):
            runner = FakeRunner()
            runner.execute = mock.Mock(side_effect=[
                {"skill": "caveman", "available": True, "loaded": True}, response
            ])
            with self.subTest(response=response), self.assertRaises(system_cavify.CavifyError):
                system_cavify.cavify({"base_instructions": "long"}, runner)

    def test_validation_rejects_structure_and_non_target_changes(self):
        original = {"keep": [1, 2], "base_instructions": "long"}
        with self.assertRaises(system_cavify.CavifyError):
            system_cavify.validate_result(original, {"keep": [1], "base_instructions": "x"}, {("base_instructions",)})
        with self.assertRaisesRegex(system_cavify.CavifyError, "non-target"):
            system_cavify.validate_result(original, {"keep": [1, 3], "base_instructions": "x"}, {("base_instructions",)})
        with self.assertRaises(system_cavify.CavifyError):
            system_cavify.validate_result(original, {"base_instructions": "x", "keep": [1, 2]}, {("base_instructions",)})


class RunnerTests(unittest.TestCase):
    def make_runner(self, directory):
        return system_cavify.CodexRunner(directory, timeout=0.01)

    @mock.patch("system_cavify.subprocess.run", side_effect=FileNotFoundError)
    def test_missing_codex(self, _run):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(system_cavify.CavifyError, "not found"):
                self.make_runner(directory).execute("p", {})

    @mock.patch("system_cavify.subprocess.run", side_effect=subprocess.TimeoutExpired("codex", 1))
    def test_timeout(self, _run):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(system_cavify.CavifyError, "timed out"):
                self.make_runner(directory).execute("p", {})

    @mock.patch("system_cavify.subprocess.run")
    def test_process_failure(self, run):
        run.return_value = subprocess.CompletedProcess([], 2, "noise", "bad news")
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(system_cavify.CavifyError, "status 2"):
                self.make_runner(directory).execute("p", {})

    @mock.patch("system_cavify.subprocess.run")
    def test_invalid_model_json(self, run):
        def invoke(command, **_kwargs):
            output = Path(command[command.index("--output-last-message") + 1])
            output.write_text("not json", encoding="utf-8")
            return subprocess.CompletedProcess(command, 0, "captured", "captured")
        run.side_effect = invoke
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(system_cavify.CavifyError, "invalid JSON"):
                self.make_runner(directory).execute("p", {})


class MainTests(unittest.TestCase):
    def test_invalid_input_has_no_stdout(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text("{", encoding="utf-8")
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                status = system_cavify.main([str(path)])
            self.assertEqual(status, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("error", stderr.getvalue())

    def test_non_standard_nan_input_has_no_stdout(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text('{"value": NaN}', encoding="utf-8")
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                status = system_cavify.main([str(path)])
            self.assertEqual(status, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("invalid JSON", stderr.getvalue())

    @mock.patch("system_cavify.cavify", side_effect=system_cavify.CavifyError("boom"))
    def test_processing_error_has_no_stdout(self, _cavify):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.json"
            path.write_text('{"x": 1}', encoding="utf-8")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
                status = system_cavify.main([str(path)])
            self.assertEqual(status, 1)
            self.assertEqual(stdout.getvalue(), "")

    @mock.patch("system_cavify.CodexRunner")
    def test_success_pretty_prints_and_does_not_modify_input(self, runner_class):
        runner_class.return_value = FakeRunner(["short"])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.json"
            original = '{"base_instructions":"long","ü":"✓"}'
            path.write_text(original, encoding="utf-8")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(io.StringIO()):
                status = system_cavify.main([str(path)])
            self.assertEqual(status, 0)
            self.assertEqual(path.read_text(encoding="utf-8"), original)
            self.assertEqual(json.loads(stdout.getvalue())["base_instructions"], "short")
            self.assertIn('  "ü": "✓"', stdout.getvalue())
            self.assertTrue(stdout.getvalue().endswith("\n"))


if __name__ == "__main__":
    unittest.main()

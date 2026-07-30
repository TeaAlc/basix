import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "validate.py"
CONTRACT_REFERENCE = ROOT / "references" / "communication-contract.md"
SPEC = importlib.util.spec_from_file_location("authoring_validate", SCRIPT)
validator = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(validator)


def plan(sequence=1, revision=1, checklist=None):
    return {
        "contract_version": "1.0", "message_type": "plan", "agent_name": "tester",
        "task_name": "task", "sequence": sequence, "status": "planned",
        "summary": "Inspect and report.",
        "data": {"plan_revision": revision, "checklist": checklist or [
            {"id": "inspect", "text": "Inspect inputs", "checked": False},
            {"id": "report", "text": "Report findings", "checked": False},
        ]}, "errors": [],
    }


UNSET = object()

RESEARCHER_PREAMBLE = """For web research, expect and use the Scrapling
MCP server (spelled `scrapling`) when it is needed. Before work, inspect the complete available tool inventory, including deferred
tools exposed through tool discovery. Do not infer that Scrapling is unavailable
from MCP resources or resource templates. Scrapling access is explicitly authorized for read-only research.
If unavailable, immediately report an `issue` with status `blocked` and finish with a
`failed` final result.
"""


def final(sequence=2, status="completed", errors=None, data=UNSET):
    return {
        "contract_version": "1.0", "message_type": "final_result", "agent_name": "tester",
        "task_name": "task", "sequence": sequence, "status": status,
        "summary": "Work finished.", "data": {} if data is UNSET else data,
        "errors": [] if errors is None else errors,
    }


def error(details=False):
    value = {"code": "E_TEST", "message": "A failure occurred", "severity": "error", "retryable": False}
    if details:
        value["details"] = {"evidence": "full"}
    return value


class MessageTests(unittest.TestCase):
    def test_all_message_types(self):
        messages = [plan()]
        messages.append({**plan(2), "message_type": "status", "status": "in_progress"})
        messages.append({**plan(3), "message_type": "issue", "status": "blocked", "data": None, "errors": [error()]})
        messages.append({**plan(4), "message_type": "permission_request", "status": "blocked", "data": {
            "request_id": "p1", "action": "read outside workspace", "reason": "Evidence required",
            "required_permission": "filesystem read", "scope": "/external/file", "blocks_current_step": True,
        }})
        messages.append({**plan(5), "message_type": "intermediate_result", "status": "in_progress", "data": None})
        messages.append(final(6))
        for message in messages:
            validator.validate_message(message)

    def test_rejects_extra_field_and_wrong_version(self):
        with self.assertRaises(validator.Invalid):
            validator.validate_message({**plan(), "extra": True})
        with self.assertRaises(validator.Invalid):
            validator.validate_message({**plan(), "contract_version": "2.0"})

    def test_word_limits(self):
        message = plan()
        message["summary"] = " ".join(["word"] * 65)
        with self.assertRaisesRegex(validator.Invalid, "64"):
            validator.validate_message(message)
        message = plan()
        message["data"]["checklist"][0]["text"] = " ".join(["word"] * 13)
        with self.assertRaisesRegex(validator.Invalid, "12"):
            validator.validate_message(message)

    def test_permission_fields_required(self):
        message = {**plan(), "message_type": "permission_request", "status": "blocked", "data": {
            "request_id": "p1", "action": "act", "reason": "why", "required_permission": "network",
            "scope": "host", "blocks_current_step": True,
        }}
        validator.validate_message(message)
        del message["data"]["scope"]
        with self.assertRaisesRegex(validator.Invalid, "missing fields"):
            validator.validate_message(message)

    def test_issue_and_intermediate_forbid_details(self):
        for kind in ("issue", "intermediate_result"):
            message = {**plan(), "message_type": kind, "status": "blocked", "data": None, "errors": [error(True)]}
            with self.assertRaisesRegex(validator.Invalid, "details"):
                validator.validate_message(message)

    def test_final_status_error_relationships(self):
        with self.assertRaises(validator.Invalid):
            validator.validate_message(final(status="completed", errors=[error()]))
        with self.assertRaises(validator.Invalid):
            validator.validate_message(final(status="failed"))
        with self.assertRaises(validator.Invalid):
            validator.validate_message(final(status="completed_with_errors", errors=[error()], data=None))
        validator.validate_message(final(status="failed", errors=[error()], data=None))


class StreamTests(unittest.TestCase):
    def test_valid_stream(self):
        status = {**plan(2), "message_type": "status", "status": "in_progress"}
        status["data"]["checklist"][0]["checked"] = True
        validator.validate_stream([plan(), status, final(3)])

    def test_requires_plan_and_one_final(self):
        with self.assertRaisesRegex(validator.Invalid, "first task message"):
            validator.validate_stream([final(1)])
        with self.assertRaisesRegex(validator.Invalid, "exactly one"):
            validator.validate_stream([plan()])

    def test_sequence_strictly_increases(self):
        with self.assertRaisesRegex(validator.Invalid, "strictly increasing"):
            validator.validate_stream([plan(2), final(2)])

    def test_no_message_after_final(self):
        with self.assertRaisesRegex(validator.Invalid, "follows final"):
            validator.validate_stream([plan(), final(2), final(3)])

    def test_revision_requires_revised_plan(self):
        status = {**plan(2, revision=2), "message_type": "status", "status": "in_progress"}
        with self.assertRaisesRegex(validator.Invalid, "revision requires"):
            validator.validate_stream([plan(), status, final(3)])

    def test_revised_plan_increments_and_preserves_stable_ids(self):
        revised = plan(2, revision=2)
        validator.validate_stream([plan(), revised, final(3)])
        changed = plan(2, revision=2)
        changed["data"]["checklist"][0]["text"] = "Changed meaning"
        with self.assertRaisesRegex(validator.Invalid, "changed text"):
            validator.validate_stream([plan(), changed, final(3)])

    def test_complete_contract_flow(self):
        first = plan()
        status = {**plan(2), "message_type": "status", "status": "in_progress"}
        status["data"]["checklist"][0]["checked"] = True
        issue = {**plan(3), "message_type": "issue", "status": "blocked",
                 "data": None, "errors": [error()]}
        permission = {**plan(4), "message_type": "permission_request", "status": "blocked",
                      "data": {"request_id": "p1", "action": "read evidence", "reason": "Needed",
                               "required_permission": "filesystem read", "scope": "/outside",
                               "blocks_current_step": True}, "errors": []}
        intermediate = {**plan(5), "message_type": "intermediate_result", "status": "in_progress",
                        "data": None, "errors": []}
        revised_items = [
            {"id": "inspect", "text": "Inspect inputs", "checked": True},
            {"id": "report", "text": "Report findings", "checked": False},
            {"id": "verify", "text": "Verify new evidence", "checked": False},
        ]
        revised = plan(6, revision=2, checklist=revised_items)
        revised_status = {**plan(7, revision=2, checklist=revised_items),
                          "message_type": "status", "status": "in_progress"}
        validator.validate_stream([
            first, status, issue, permission, intermediate, revised, revised_status, final(8)
        ])


class AgentTests(unittest.TestCase):
    def write_agent(self, model="gpt-5.6-luna", effort="medium", marker="", block=True,
                    description="Basix-Agent: Test agent", name="agent", sandbox="read-only",
                    preamble=None):
        reference = CONTRACT_REFERENCE.read_text()
        contract = reference[reference.index(validator.START):reference.index(validator.END) + len(validator.END)]
        if not block:
            contract = "Instructions without a managed communication contract."
        if preamble is None:
            preamble = RESEARCHER_PREAMBLE if name == "basix_researcher" else ""
        text = f'''name = "{name}"\ndescription = "{description}"\n{marker}model = "{model}"\nmodel_reasoning_effort = "{effort}"\nsandbox_mode = "{sandbox}"\ndeveloper_instructions = """{preamble}{contract}"""\n'''
        directory = tempfile.TemporaryDirectory()
        path = Path(directory.name) / "agent.toml"
        path.write_text(text)
        return directory, path

    def test_default_agent(self):
        directory, path = self.write_agent()
        with directory:
            validator.validate_agent(path)

    def test_description_requires_prefix_at_start(self):
        for description in ("Test agent", "Test Basix-Agent: agent"):
            directory, path = self.write_agent(description=description)
            with directory, self.assertRaisesRegex(validator.Invalid, "description must begin"):
                validator.validate_agent(path)

    def test_non_luna_requires_adjacent_override(self):
        directory, path = self.write_agent(model="custom")
        with directory, self.assertRaisesRegex(validator.Invalid, "override"):
            validator.validate_agent(path)
        directory, path = self.write_agent(model="custom", effort="extreme", marker=validator.OVERRIDE + "\n")
        with directory:
            validator.validate_agent(path)

    def test_default_effort_and_contract_rejected(self):
        directory, path = self.write_agent(effort="extreme")
        with directory, self.assertRaisesRegex(validator.Invalid, "effort"):
            validator.validate_agent(path)
        directory, path = self.write_agent(block=False)
        with directory, self.assertRaisesRegex(validator.Invalid, "markers"):
            validator.validate_agent(path)

    def test_rejects_shortened_or_changed_contract(self):
        for replacement in ("Send exactly one `final_result`.", "Send at most one `final_result`."):
            directory, path = self.write_agent()
            text = path.read_text()
            if replacement.startswith("Send exactly"):
                text = text.replace(replacement, "")
            else:
                text = text.replace("Send exactly one `final_result`.", replacement)
            path.write_text(text)
            with directory, self.assertRaisesRegex(validator.Invalid, "differs from canonical"):
                validator.validate_agent(path)

    def test_requires_read_only_sandbox(self):
        for sandbox in ("workspace-write", "danger-full-access", ""):
            directory, path = self.write_agent(sandbox=sandbox)
            with directory, self.assertRaisesRegex(validator.Invalid, "sandbox_mode"):
                validator.validate_agent(path)

    def test_file_explorer_requires_luna_low_without_override(self):
        directory, path = self.write_agent(name="basix_file_explorer", effort="low")
        with directory:
            validator.validate_agent(path)
        directory, path = self.write_agent(name="basix_file_explorer", effort="medium")
        with directory, self.assertRaisesRegex(validator.Invalid, "low reasoning"):
            validator.validate_agent(path)
        directory, path = self.write_agent(name="basix_file_explorer", model="custom", effort="low",
                                           marker=validator.OVERRIDE + "\n")
        with directory, self.assertRaisesRegex(validator.Invalid, "gpt-5.6-luna"):
            validator.validate_agent(path)

    def test_researcher_policy_is_fixed(self):
        directory, path = self.write_agent(name="basix_researcher")
        with directory:
            validator.validate_agent(path)
        cases = [
            {"model": "custom"},
            {"model": "custom", "marker": validator.OVERRIDE + "\n"},
            {"marker": validator.OVERRIDE + "\n"},
            {"effort": "low"},
            {"effort": "high"},
            {"sandbox": "workspace-write"},
        ]
        for kwargs in cases:
            directory, path = self.write_agent(name="basix_researcher", **kwargs)
            with directory, self.assertRaises(validator.Invalid):
                validator.validate_agent(path)

    def test_researcher_requires_scrapling_policy(self):
        directory, path = self.write_agent(name="basix_researcher", preamble="")
        with directory, self.assertRaisesRegex(validator.Invalid, "Scrapling researcher policy"):
            validator.validate_agent(path)


class CliTests(unittest.TestCase):
    def run_cli(self, command, payload):
        return subprocess.run([sys.executable, str(SCRIPT), command, "--stdin"], input=payload,
                              text=True, capture_output=True, check=False)

    def test_message_stdin(self):
        result = self.run_cli("message", json.dumps(plan()))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "valid")

    def test_stream_is_json_lines_not_array(self):
        payload = "\n".join(json.dumps(value) for value in (plan(), final()))
        result = self.run_cli("stream", payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_cli("stream", json.dumps([plan(), final()]))
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()

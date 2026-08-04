import importlib.util
import io
import json
import re
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "validate.py"
CONTRACT_REFERENCE = ROOT / "references" / "communication-contract.md"
PAGER_NATIVE = ROOT.parents[1] / "agents" / "native" / "basix-pager.toml"
VERIFIER_NATIVE = ROOT.parents[1] / "agents" / "native" / "basix-verifier.toml"
SPEC = importlib.util.spec_from_file_location("authoring_validate", SCRIPT)
validator = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(validator)


def plan(sequence=1, revision=1, checklist=None, cycle=1, agent="tester", task="task"):
    return {
        "contract_version": "1.2", "message_type": "plan", "agent_name": agent,
        "task_name": task, "sequence": sequence, "cycle_revision": cycle, "status": "planned",
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
In both reports, tell `/root` to install Scrapling with
the Basix installer `install-scrapling-codex.sh`. Also explain that Basix
Scrapling requires Podman and routes all web requests through the Tor network.
"""


def final(sequence=2, status="completed", errors=None, data=UNSET, cycle=1, agent="tester", task="task"):
    return {
        "contract_version": "1.2", "message_type": "final_result", "agent_name": agent,
        "task_name": task, "sequence": sequence, "cycle_revision": cycle, "status": status,
        "summary": "Work finished.", "data": {} if data is UNSET else data,
        "errors": [] if errors is None else errors,
    }


def report_started(sequence, report_type, cycle=1, agent="tester", task="task"):
    return {
        "contract_version": "1.2", "message_type": "report_started", "agent_name": agent,
        "task_name": task, "sequence": sequence, "cycle_revision": cycle, "status": "in_progress",
        "summary": "Preparing requested report.", "data": {"report_type": report_type}, "errors": [],
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
        messages.append(report_started(5, "intermediate_result"))
        messages.append({**plan(6), "message_type": "intermediate_result", "status": "in_progress", "data": None})
        messages.append(final(7))
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

    def test_report_started_fields(self):
        validator.validate_message(report_started(1, "intermediate_result"))
        validator.validate_message(report_started(1, "final_result"))
        for mutation, expected in (
            ({"status": "blocked"}, "status"),
            ({"data": {"report_type": "status"}}, "report_type"),
            ({"data": {}}, "missing fields"),
            ({"errors": [error()]}, "errors must be empty"),
        ):
            with self.subTest(mutation=mutation), self.assertRaisesRegex(validator.Invalid, expected):
                validator.validate_message({**report_started(1, "intermediate_result"), **mutation})

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
        announcement = report_started(5, "intermediate_result")
        intermediate = {**plan(6), "message_type": "intermediate_result", "status": "in_progress",
                        "data": None, "errors": []}
        revised_items = [
            {"id": "inspect", "text": "Inspect inputs", "checked": True},
            {"id": "report", "text": "Report findings", "checked": False},
            {"id": "verify", "text": "Verify new evidence", "checked": False},
        ]
        revised = plan(7, revision=2, checklist=revised_items)
        revised_status = {**plan(8, revision=2, checklist=revised_items),
                          "message_type": "status", "status": "in_progress"}
        validator.validate_stream([
            first, status, issue, permission, announcement, intermediate, revised, revised_status, final(9)
        ])

    def test_review_fix_final_flow_is_terminal(self):
        first = plan()
        announcement = report_started(2, "intermediate_result")
        review = {**plan(3), "message_type": "intermediate_result", "status": "in_progress", "data": None}
        revised = plan(4, revision=2)
        fixed_status = {**plan(5, revision=2), "message_type": "status", "status": "in_progress"}
        terminal = final(6)
        validator.validate_stream([first, announcement, review, revised, fixed_status, terminal])
        with self.assertRaisesRegex(validator.Invalid, "follows final"):
            validator.validate_stream([first, final(2), {**announcement, "sequence": 3}])

    def test_requested_final_is_announced_and_terminal(self):
        validator.validate_stream([plan(), report_started(2, "final_result"), final(3)])

    def test_autonomous_final_needs_no_announcement(self):
        validator.validate_stream([plan(), final(2)])

    def test_report_type_must_match_announcement(self):
        with self.assertRaisesRegex(validator.Invalid, "expected announced intermediate_result"):
            validator.validate_stream([plan(), report_started(2, "intermediate_result"), final(3)])
        intermediate = {**plan(3), "message_type": "intermediate_result", "status": "in_progress", "data": None}
        with self.assertRaisesRegex(validator.Invalid, "expected announced final_result"):
            validator.validate_stream([plan(), report_started(2, "final_result"), intermediate, final(4)])

    def test_rejects_duplicate_and_uncompleted_announcement(self):
        with self.assertRaisesRegex(validator.Invalid, "expected announced intermediate_result"):
            validator.validate_stream([
                plan(), report_started(2, "intermediate_result"),
                report_started(3, "intermediate_result"), final(4),
            ])
        with self.assertRaisesRegex(validator.Invalid, "uncompleted report_started"):
            validator.validate_stream([plan(), report_started(2, "final_result")])

    def test_only_operational_messages_allowed_during_report_preparation(self):
        status = {**plan(3), "message_type": "status", "status": "in_progress"}
        issue = {**plan(4), "message_type": "issue", "status": "blocked", "data": None, "errors": [error()]}
        permission = {**plan(5), "message_type": "permission_request", "status": "blocked", "data": {
            "request_id": "p1", "action": "read evidence", "reason": "Needed",
            "required_permission": "filesystem read", "scope": "/outside", "blocks_current_step": True,
        }}
        intermediate = {**plan(6), "message_type": "intermediate_result", "status": "in_progress", "data": None}
        validator.validate_stream([
            plan(), report_started(2, "intermediate_result"), status, issue, permission,
            intermediate, final(7),
        ])

    def test_intermediate_result_requires_announcement(self):
        intermediate = {**plan(2), "message_type": "intermediate_result", "status": "in_progress", "data": None}
        with self.assertRaisesRegex(validator.Invalid, "requires report_started"):
            validator.validate_stream([plan(), intermediate, final(3)])

    def test_continuation_requires_incremented_cycle_and_new_plan(self):
        continued = plan(3, cycle=2)
        continued_status = {**plan(4, cycle=2), "message_type": "status", "status": "in_progress"}
        validator.validate_stream([plan(), final(2), continued, continued_status, final(5, cycle=2)])

    def test_post_final_activity_without_continuation_is_rejected(self):
        status = {**plan(3), "message_type": "status", "status": "in_progress"}
        with self.assertRaisesRegex(validator.Invalid, "follows final"):
            validator.validate_stream([plan(), final(2), status])

    def test_unchanged_cycle_revision_cannot_reactivate(self):
        with self.assertRaisesRegex(validator.Invalid, "follows final|cycle_revision"):
            validator.validate_stream([plan(), final(2), plan(3, cycle=1)])

    def test_cycle_revision_must_advance_one_and_reset_plan_revision(self):
        with self.assertRaisesRegex(validator.Invalid, "increase by exactly one"):
            validator.validate_stream([plan(), final(2), plan(3, cycle=3)])
        with self.assertRaisesRegex(validator.Invalid, "plan_revision 1"):
            validator.validate_stream([plan(), final(2), plan(3, revision=2, cycle=2)])

    def test_sequence_is_global_for_agent_lifetime(self):
        with self.assertRaisesRegex(validator.Invalid, "strictly increasing"):
            validator.validate_stream([plan(2), final(3), plan(1, cycle=2), final(4, cycle=2)])


class AgentTests(unittest.TestCase):
    def test_canonical_pager_definition_and_profiles(self):
        validator.validate_agent(PAGER_NATIVE)
        agent = tomllib.loads(PAGER_NATIVE.read_text())
        self.assertEqual(agent["name"], "basix_pager")
        self.assertEqual(agent["model"], "gpt-5.6-luna")
        self.assertEqual(agent["model_reasoning_effort"], "max")
        self.assertEqual(agent["sandbox_mode"], "workspace-write")
        instructions = agent["developer_instructions"]
        for profile in ("ui_ux", "frontend", "backend_web", "fullstack", "integration"):
            self.assertIn(f"`{profile}`", instructions)
        for phrase in ("fork_turns=\"none\"", ".basix/contracts/<chain-id>.md", "intermediate_result", "final_result"):
            self.assertIn(phrase, instructions)

    def test_canonical_verifier_definition(self):
        validator.validate_agent(VERIFIER_NATIVE)
        agent = tomllib.loads(VERIFIER_NATIVE.read_text())
        self.assertEqual(agent["name"], "basix_verifier")
        self.assertEqual(agent["model"], "gpt-5.6-luna")
        self.assertEqual(agent["model_reasoning_effort"], "max")
        self.assertEqual(agent["sandbox_mode"], "read-only")
        instructions = agent["developer_instructions"]
        for phrase in ("immutable", "inconclusive", "remediation", "fork_turns=\"none\"",
                       "Fingerprint", "followup_task", "cycle_revision"):
            self.assertIn(phrase, instructions)

    def write_agent(self, model="gpt-5.6-luna", effort="medium", marker="", block=True,
                    description="Basix-Agent: Test agent", name="agent", sandbox="read-only",
                    sandbox_marker="", preamble=None):
        reference = CONTRACT_REFERENCE.read_text()
        contract = reference[reference.index(validator.START):reference.index(validator.END) + len(validator.END)]
        if not block:
            contract = "Instructions without a managed communication contract."
        if preamble is None:
            preamble = RESEARCHER_PREAMBLE if name == "basix_researcher" else ""
        text = f'''name = "{name}"\ndescription = "{description}"\n{marker}model = "{model}"\nmodel_reasoning_effort = "{effort}"\n{sandbox_marker}sandbox_mode = "{sandbox}"\ndeveloper_instructions = """{preamble}{contract}"""\n'''
        directory = tempfile.TemporaryDirectory()
        path = Path(directory.name) / "agent.toml"
        path.write_text(text)
        return directory, path

    def test_default_agent(self):
        directory, path = self.write_agent()
        with directory:
            validator.validate_agent(path)

    def test_highly_complex_agent_uses_luna_max_without_override(self):
        directory, path = self.write_agent(effort="max")
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
            with directory, self.assertRaisesRegex(validator.Invalid, "sandbox_mode|workspace-write"):
                validator.validate_agent(path)

    def test_pager_max_is_classified_and_workspace_write_needs_marker(self):
        directory, path = self.write_agent(name="basix_pager", effort="max", sandbox="workspace-write")
        with directory, self.assertRaisesRegex(validator.Invalid, "sandbox override"):
            validator.validate_agent(path)

        directory, path = self.write_agent(
            name="basix_pager", effort="max", sandbox="workspace-write",
            sandbox_marker=validator.SANDBOX_OVERRIDE + "\n",
        )
        with directory:
            validator.validate_agent(path)

        directory, path = self.write_agent(
            name="basix_pager", effort="max", marker=validator.OVERRIDE + "\n",
            sandbox="workspace-write", sandbox_marker=validator.SANDBOX_OVERRIDE + "\n",
        )
        with directory, self.assertRaisesRegex(validator.Invalid, "without an override"):
            validator.validate_agent(path)

        directory, path = self.write_agent(
            name="basix_pager", effort="high", sandbox="workspace-write",
            sandbox_marker=validator.SANDBOX_OVERRIDE + "\n",
        )
        with directory, self.assertRaisesRegex(validator.Invalid, "max reasoning"):
            validator.validate_agent(path)

    def test_verifier_uses_classified_max_without_override_and_read_only(self):
        directory, path = self.write_agent(name="basix_verifier", effort="max")
        with directory:
            validator.validate_agent(path)
        directory, path = self.write_agent(name="basix_verifier", effort="max", sandbox="workspace-write")
        with directory, self.assertRaisesRegex(validator.Invalid, "reserved for basix_pager|read-only"):
            validator.validate_agent(path)

        directory, path = self.write_agent(name="basix_verifier", effort="max", marker=validator.OVERRIDE + "\n")
        with directory, self.assertRaisesRegex(validator.Invalid, "without an override"):
            validator.validate_agent(path)

    def test_sandbox_override_is_reserved_for_pager(self):
        directory, path = self.write_agent(
            name="agent", sandbox="workspace-write", sandbox_marker=validator.SANDBOX_OVERRIDE + "\n",
        )
        with directory, self.assertRaisesRegex(validator.Invalid, "reserved for basix_pager"):
            validator.validate_agent(path)

        directory, path = self.write_agent(
            name="agent", sandbox_marker=validator.SANDBOX_OVERRIDE + "\n",
        )
        with directory, self.assertRaisesRegex(validator.Invalid, "reserved for basix_pager"):
            validator.validate_agent(path)

    def test_model_and_sandbox_fields_must_be_unique(self):
        directory, path = self.write_agent()
        path.write_text(path.read_text() + '\n[metadata]\nmodel = "gpt-5.6-luna"\n')
        with directory, self.assertRaisesRegex(validator.Invalid, "exactly one model field"):
            validator.validate_agent(path)

        directory, path = self.write_agent()
        path.write_text(path.read_text() + '\n[metadata]\nsandbox_mode = "read-only"\n')
        with directory, self.assertRaisesRegex(validator.Invalid, "exactly one sandbox_mode field"):
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


class RepositoryPolicyTests(unittest.TestCase):
    def test_native_agents_use_only_contract_1_2_and_validate(self):
        repository = Path(__file__).resolve().parents[4]
        agents = sorted((repository / "src/agents/native").glob("*.toml"))
        self.assertTrue(agents)
        for path in agents:
            versions = re.findall(
                r"(?i)\bcontract(?:\s+version)?\s+(\d+\.\d+)\b",
                path.read_text(),
            )
            self.assertTrue(versions, path)
            self.assertEqual(set(versions), {"1.2"}, path)
            validator.validate_agent(path)

    def test_documented_repository_test_paths_exist(self):
        repository = Path(__file__).resolve().parents[4]
        skills = (
            repository / "src/skills/basix/SKILL.md",
            repository / "src/skills/basix-agent-authoring/SKILL.md",
        )
        documented_paths = ("./src/tests/verify-basix.sh", "./src/tests/test-setup.sh")
        for skill in skills:
            text = skill.read_text()
            for documented_path in documented_paths:
                self.assertIn(documented_path, text, skill)
                self.assertTrue((repository / documented_path.removeprefix("./")).is_file())


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

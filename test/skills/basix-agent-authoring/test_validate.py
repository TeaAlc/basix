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

ROOT = Path(__file__).resolve().parents[3] / "src/skills/basix-agent-authoring"
SCRIPT = ROOT / "scripts" / "validate.py"
BOOTSTRAP_REFERENCE = ROOT / "references" / "native-agent-bootstrap.md"
CONTRACT_REFERENCE = ROOT.parent / "basix-subagent-management" / "references" / "agent-communication-contract.md"
PAGER_NATIVE = ROOT.parents[1] / "agents" / "native" / "basix-pager.toml"
VERIFIER_NATIVE = ROOT.parents[1] / "agents" / "native" / "basix-verifier.toml"
MIRACULIX_NATIVE = ROOT.parents[1] / "agents" / "native" / "basix-miraculix.toml"
SPEC = importlib.util.spec_from_file_location("authoring_validate", SCRIPT)
validator = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(validator)


UNSET = object()

RESEARCHER_PREAMBLE = """For web research, expect and use the Scrapling
MCP server (spelled `scrapling`) when it is needed. Before work, inspect the complete available tool inventory, including deferred
tools exposed through tool discovery. Do not infer that Scrapling is unavailable
from MCP resources or resource templates. Scrapling access is explicitly authorized for read-only research.
If unavailable, treat the assignment as blocked and unsuccessful under the communication
contract. Tell the spawning parent to install Scrapling with the Basix installer
`install-scrapling-codex.sh`. Also explain that Basix
Scrapling requires Podman and routes all web requests through the Tor network.
"""


def final(sequence=2, status="completed", errors=None, data=UNSET, cycle=1, agent="tester", task="task"):
    return {
        "contract_version": "2.0", "message_type": "final_result", "agent_name": agent,
        "task_name": task, "sequence": sequence, "cycle_revision": cycle, "status": status,
        "summary": "Work finished.", "data": {} if data is UNSET else data,
        "errors": [] if errors is None else errors,
    }


def error(details=False):
    value = {"code": "E_TEST", "message": "A failure occurred", "severity": "error", "retryable": False}
    if details:
        value["details"] = {"evidence": "full"}
    return value


def issue(sequence=1, **kw):
    return {**final(sequence, **kw), "message_type": "issue", "status": "blocked",
            "data": None, "errors": [error()]}


def permission(sequence=1):
    return {**final(sequence), "message_type": "permission_request", "status": "blocked",
            "data": {"request_id": "p1", "action": "read", "reason": "needed",
                     "required_permission": "read", "scope": "/external", "blocks_current_step": True}}


class MessageTests(unittest.TestCase):
    def test_allowed_and_old_messages(self):
        for message in (final(), issue(), permission()):
            validator.validate_message(message)
        for kind in ("plan", "status", "report_started", "intermediate_result"):
            with self.assertRaises(validator.Invalid):
                validator.validate_message({**final(), "message_type": kind})
        for mutation in ({"contract_version": "1.4"}, {"extra": True}, {"sequence": True}, {"cycle_revision": 0}):
            with self.assertRaises(validator.Invalid):
                validator.validate_message({**final(), **mutation})

    def test_final_error_semantics(self):
        for message in (final(status="failed", errors=[error()]),
                        final(status="completed_with_errors", errors=[error()], data={"result": "partial"})):
            validator.validate_message(message)
        for message in (final(errors=[error()]), final(status="failed"),
                        final(status="completed_with_errors", errors=[error()], data=None)):
            with self.assertRaises(validator.Invalid): validator.validate_message(message)

    def test_blocker_and_permission_boundaries(self):
        for message in ({**issue(), "summary": "word " * 33},
                        {**issue(), "errors": [error(details=True)]},
                        {**issue(), "errors": []}, {**permission(), "data": {}}):
            with self.assertRaises(validator.Invalid): validator.validate_message(message)

    def test_insight_boundaries(self):
        validator.validate_message(final(data={"subagent_insights": ["Reuse focused logs"]}))
        for insights in ([], [""], ["word " * 25], "wrong"):
            with self.assertRaises(validator.Invalid):
                validator.validate_message(final(data={"subagent_insights": insights}))
        with self.assertRaises(validator.Invalid):
            validator.validate_message({**permission(), "data": {**permission()["data"], "subagent_insights": ["No"]}})


class SchemaCliParityTests(unittest.TestCase):
    """Use installed Draft2020-12 tooling, without a runtime dependency."""

    @classmethod
    def setUpClass(cls):
        try:
            from jsonschema import Draft202012Validator
        except ImportError:
            raise unittest.SkipTest("optional jsonschema unavailable; portable patterns tested separately")
        schema = json.loads((ROOT / "references/message.schema.json").read_text())
        Draft202012Validator.check_schema(schema)
        cls.schema = Draft202012Validator(schema)

    def assert_parity(self, message, accepted):
        self.assertEqual(self.schema.is_valid(message), accepted, message)
        result = subprocess.run([sys.executable, str(SCRIPT), "message", "--stdin"],
                                input=json.dumps(message), text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, accepted, result.stderr)

    def test_word_limits_and_unicode_whitespace(self):
        for separator in (" ", "\t", "\n", "\u001c", "\u0085", "\u00a0", "\u1680",
                          "\u2003", "\u2028", "\u2029", "\u202f", "\u205f", "\u3000"):
            for limit, kind in ((24, "insight"), (32, "issue")):
                for count in (limit, limit + 1):
                    # Punctuation and non-Latin scripts are whitespace-delimited words too.
                    value = separator + separator.join(["词-?!"] * count) + separator
                    message = (final(data={"subagent_insights": [value]}) if kind == "insight"
                               else {**issue(), "summary": value})
                    with self.subTest(separator=repr(separator), kind=kind, count=count):
                        self.assert_parity(message, count == limit)
        # FEFF and zero-width space are not Python whitespace; do not use ECMAScript \s.
        for separator in ("\ufeff", "\u200b"):
            self.assert_parity(final(data={"subagent_insights": [separator.join(["word"] * 25)]}), True)

    def test_empty_whitespace_and_non_string_values(self):
        for value in ("", " \t\n\u001c\u0085\u3000", None, 1, True, [], {}):
            messages = [final(data={"subagent_insights": [value]}), {**issue(), "summary": value}]
            for key in ("agent_name", "task_name", "summary"):
                messages.append({**final(), key: value})
            for key in ("code", "message"):
                messages.append({**issue(), "errors": [{**error(), key: value}]})
            for key in ("request_id", "action", "reason", "required_permission", "scope"):
                messages.append({**permission(), "data": {**permission()["data"], key: value}})
            for message in messages:
                with self.subTest(value=value, message=message):
                    self.assert_parity(message, False)

    def test_long_single_word_has_no_arbitrary_character_limit(self):
        value = "x" * 10000
        self.assert_parity(final(data={"subagent_insights": [value]}), True)
        self.assert_parity({**issue(), "summary": value}, True)

    def test_integer_numeric_boundaries(self):
        """Compare both numeric fields through schema and actual CLI parsing."""
        for key in ("sequence", "cycle_revision"):
            for value, accepted in ((1, True), (1.0, True), (2.0, True),
                                    (1.5, False), (True, False), (False, False),
                                    (0, False), (0.0, False), (-1, False), (-1.0, False),
                                    (float("nan"), False), (float("inf"), False),
                                    (float("-inf"), False)):
                with self.subTest(key=key, value=value):
                    self.assert_parity({**final(), key: value}, accepted)

    def test_unhashable_enum_parity(self):
        """Arrays and objects fail schema and CLI enum constraints without traceback."""
        for key in ("message_type", "status", "severity"):
            for value in ([], {}):
                message = ({**issue(), "errors": [{**error(), key: value}]}
                           if key == "severity" else {**final(), key: value})
                with self.subTest(key=key, value=value):
                    self.assert_parity(message, False)


class StreamTests(unittest.TestCase):
    def test_cli_integral_float_cycles_and_exact_replay(self):
        """Keep raw numeric representation significant for terminal replay."""
        terminal = final(1.0, cycle=1.0)
        fixtures = (([terminal, terminal], True),
                    ([terminal, final(2.0, cycle=2.0), terminal], True),
                    ([terminal, final(1, cycle=1.0)], False),
                    ([terminal, final(1.0, cycle=1)], False),
                    ([issue(1.0), final(2.0)], True))
        for stream, accepted in fixtures:
            with self.subTest(stream=stream):
                result = subprocess.run([sys.executable, str(SCRIPT), "stream", "--stdin"],
                                        input="\n".join(json.dumps(m) for m in stream),
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_integral_float_sequence_uses_integer_arithmetic(self):
        """Sequence comparisons preserve exact parsed values above float precision."""
        large = 2.0 ** 53
        validator.validate_stream([issue(large), final(int(large) + 1)])
        with self.assertRaises(validator.Invalid):
            validator.validate_stream([issue(int(large) + 1), final(large)])

    def test_silent_and_blocker_cycles(self):
        for stream in ([final(1)], [issue(), final(2)], [permission(), final(2)],
                       [final(1, status="failed", errors=[error()])],
                       [final(1), final(2, cycle=2)], [issue(), final(2), issue(3, cycle=2), final(4, cycle=2)]):
            validator.validate_stream(stream)

    def test_related_remediation_cycles_keep_identity_and_replays(self):
        original = final(1, data={"changed_paths": ["src/original.py"]})
        corrected = final(2, cycle=2, data={"changed_paths": ["src/fix.py"],
                                               "acceptance_criteria": ["new boundary"]})
        validator.validate_stream([original, corrected, original])
        with self.assertRaisesRegex(validator.Invalid, "task_name changed"):
            validator.validate_stream([original, {**corrected, "task_name": "replacement"}])
        with self.assertRaisesRegex(validator.Invalid, "replay"):
            validator.validate_stream([original, corrected, {**original, "summary": "altered"}])

    def test_exact_terminal_replay_before_and_after_continuation(self):
        terminal = final(1)
        validator.validate_stream([terminal, terminal])
        validator.validate_stream([terminal, final(2, cycle=2), terminal])
        validator.validate_stream([terminal, issue(2, cycle=2), terminal, final(3, cycle=2)])
        validator.validate_stream([terminal, final(2, cycle=2), final(3, cycle=3),
                                   issue(4, cycle=4), terminal, final(5, cycle=4), terminal])

    def test_invalid_lifecycle(self):
        terminal = final(1)
        streams = ([], [issue()], [terminal, final(2)],
                   [terminal, {**terminal, "summary": "altered"}],
                   [final(1, data={"value": True}), final(1, data={"value": 1})],
                   [issue(), issue()], [permission(), permission()], [issue(2), final(1)],
                   [final(1, cycle=2)], [terminal, final(2, cycle=3)],
                   [issue(), final(2, cycle=2)], [terminal, final(2, task="other")],
                   [terminal, final(1, cycle=2)], [terminal, issue(2)],
                   [terminal, issue(2, cycle=2), terminal])
        for stream in streams:
            with self.subTest(stream=stream), self.assertRaises(validator.Invalid):
                validator.validate_stream(stream)

    def test_cli_replay_lifecycle_fixtures(self):
        terminal = final(1)
        positive = [terminal, issue(2, cycle=2), terminal, final(3, cycle=2),
                    final(4, cycle=3), final(5, cycle=4), terminal]
        fixtures = [(positive, True),
                    ([terminal, {**terminal, "data": {"changed": True}}], False),
                    ([final(1, data={"value": True}), final(1, data={"value": 1})], False),
                    ([permission(), permission(), final(2)], False),
                    ([issue(), issue(), final(2)], False),
                    ([terminal, final(2, cycle=3)], False),
                    ([terminal, final(2, cycle=2, task="other")], False),
                    ([terminal, final(1, cycle=2)], False),
                    ([terminal, issue(2, cycle=2), terminal], False)]
        for stream, accepted in fixtures:
            with self.subTest(stream=stream):
                result = subprocess.run([sys.executable, str(SCRIPT), "stream", "--stdin"],
                                        input="\n".join(json.dumps(m) for m in stream),
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)

    def test_independent_agent_identity(self):
        validator.validate_stream([final(1, agent="a"), final(1, agent="b")])
        with self.assertRaises(validator.Invalid):
            validator.validate_stream([final(1, agent="a"), issue(1, agent="b")])


class AgentTests(unittest.TestCase):
    def test_canonical_miraculix_definition_and_prompt(self):
        validator.validate_agent(MIRACULIX_NATIVE)
        text = MIRACULIX_NATIVE.read_text()
        agent = tomllib.loads(text)
        self.assertEqual(agent["name"], "basix_miraculix")
        self.assertEqual(agent["model"], "gpt-6-astra")
        self.assertEqual(agent["model_reasoning_effort"], "low")
        self.assertEqual(agent["sandbox_mode"], "read-only")
        model_line = text.splitlines().index('model = "gpt-6-astra"')
        self.assertEqual(text.splitlines()[model_line - 1], validator.OVERRIDE)
        instructions = agent["developer_instructions"]
        for phrase in (
            "one or more non-empty string values", "combined length of only the",
            "question values, counting", "question values",
            "1024 Unicode characters", "inherit no parent state",
            "use no domain tools, files, web access, or subagents",
            "Prior answers from your own explicitly authorized",
            "spawning parent\nalone decides", "a new topic requires a new,\nfresh agent",
            "`final_result` whose `data.answer`", "Answer every question in its\nlanguage",
            "complete answer\nmust be exactly `Das weiß ich nicht`",
            "Multiple questions may therefore mix safe\nanswers",
            "time-sensitive answers", "very strongly supported",
            "code is `invalid_request`",
        ):
            self.assertIn(phrase, instructions)

    def test_canonical_pager_definition_and_profiles(self):
        validator.validate_agent(PAGER_NATIVE)
        agent = tomllib.loads(PAGER_NATIVE.read_text())
        self.assertEqual(agent["name"], "basix_pager")
        self.assertEqual(agent["model"], "gpt-6-luna")
        self.assertEqual(agent["model_reasoning_effort"], "xhigh")
        self.assertEqual(agent["sandbox_mode"], "workspace-write")
        instructions = agent["developer_instructions"]
        for profile in ("ui_ux", "frontend", "backend_web", "fullstack", "integration"):
            self.assertIn(f"`{profile}`", instructions)
        for phrase in (".basix/contracts/<chain-id>.md", "spawning parent", "Contract 2.0"):
            self.assertIn(phrase, instructions)
        for phrase in ("intermediate_result", "send `/root`"):
            self.assertNotIn(phrase, instructions)

    def test_canonical_verifier_definition(self):
        validator.validate_agent(VERIFIER_NATIVE)
        agent = tomllib.loads(VERIFIER_NATIVE.read_text())
        self.assertEqual(agent["name"], "basix_verifier")
        self.assertEqual(agent["model"], "gpt-6-luna")
        self.assertEqual(agent["model_reasoning_effort"], "xhigh")
        self.assertEqual(agent["sandbox_mode"], "read-only")
        instructions = agent["developer_instructions"]
        for phrase in ("immutable", "inconclusive", "remediation", "fork_turns=\"none\"",
                       "write freeze", "spawning parent"):
            self.assertIn(phrase, instructions)
        for phrase in ("Fingerprint", "target drift", "followup_task", "cycle_revision",
                       "send one concise `final_result`"):
            self.assertNotIn(phrase, instructions)

    def test_all_native_roles_forbid_direct_root_recipient(self):
        repository = Path(__file__).resolve().parents[3]
        for path in sorted((repository / "src/agents/native").glob("*.toml")):
            agent = tomllib.loads(path.read_text())
            combined = agent["description"] + "\n" + agent["developer_instructions"]
            self.assertNotIn("/root", combined, path)
            self.assertIsNone(re.search(r"\bRoot\b", agent["developer_instructions"]), path)

    def test_rejects_direct_root_recipient_in_any_native_role(self):
        directory, path = self.write_agent(preamble="Send every result directly to /root.")
        with directory, self.assertRaisesRegex(validator.Invalid, "spawning parent"):
            validator.validate_agent(path)

    def write_agent(self, model="gpt-6-luna", effort="medium", marker="", block=True,
                    description="Basix-Agent: Test agent", name="basix_agent", sandbox="read-only",
                    sandbox_marker="", preamble=None, level=None, author="Basix",
                    principal_marker=False):
        reference = BOOTSTRAP_REFERENCE.read_text()
        contract = reference[
            reference.index(validator.BOOTSTRAP_START):
            reference.index(validator.BOOTSTRAP_END) + len(validator.BOOTSTRAP_END)
        ]
        if not block:
            contract = "Instructions without a managed communication contract."
        if preamble is None:
            preamble = RESEARCHER_PREAMBLE if name == "basix_researcher" else ""
        level = level or validator.CANONICAL_LEVELS.get(name, "junior")
        level_declaration = f"You are a {level} Basix agent.\n"
        principal = f"{validator.PRINCIPAL_MARKER}\n" if principal_marker else ""
        metadata = (f'{validator.METADATA_START}\n{principal}'
                    f'# metadata = {{ author = "{author}", level = "{level}" }}\n'
                    f'{validator.METADATA_END}\n')
        text = f'''{metadata}name = "{name}"\ndescription = "{description}"\n{marker}model = "{model}"\nmodel_reasoning_effort = "{effort}"\n{sandbox_marker}sandbox_mode = "{sandbox}"\ndeveloper_instructions = """{level_declaration}{preamble}{contract}"""\n'''
        directory = tempfile.TemporaryDirectory()
        path = Path(directory.name) / "agent.toml"
        path.write_text(text)
        return directory, path

    def test_default_agent(self):
        directory, path = self.write_agent()
        with directory:
            validator.validate_agent(path)

    def test_metadata_levels_and_principal_marker(self):
        for level in ("junior", "senior"):
            directory, path = self.write_agent(level=level)
            with directory:
                validator.validate_agent(path)
        directory, path = self.write_agent(level="principal", principal_marker=True)
        with directory:
            validator.validate_agent(path)

        for level, marker in (("principal", False), ("junior", True), ("unknown", False)):
            directory, path = self.write_agent(level=level, principal_marker=marker)
            with directory, self.assertRaises(validator.Invalid):
                validator.validate_agent(path)

    def test_rejects_missing_duplicate_misplaced_or_malformed_metadata(self):
        mutations = (
            lambda text: "\n".join(text.splitlines()[3:]) + "\n",
            lambda text: text.replace(validator.METADATA_END,
                                      validator.METADATA_END + "\n" + text.split(validator.METADATA_END, 1)[0] + validator.METADATA_END),
            lambda text: "# displaced\n" + text,
            lambda text: text.replace('author = "Basix"', 'author = '),
            lambda text: text.replace('author = "Basix"', 'author = ""'),
        )
        for mutate in mutations:
            directory, path = self.write_agent()
            path.write_text(mutate(path.read_text()))
            with directory, self.assertRaises(validator.Invalid):
                validator.validate_agent(path)

        for malformed in ('["junior"]', '{ value = "junior" }'):
            directory, path = self.write_agent()
            path.write_text(path.read_text().replace('level = "junior"', f"level = {malformed}"))
            with directory, self.assertRaisesRegex(validator.Invalid, "metadata level"):
                validator.validate_agent(path)

    def test_canonical_levels_are_fixed(self):
        for name, level in validator.CANONICAL_LEVELS.items():
            wrong = "senior" if level == "junior" else "junior"
            effort = {"basix_file_explorer": "low", "basix_researcher": "medium",
                      "basix_miraculix": "low",
                      "basix_pager": "xhigh", "basix_verifier": "xhigh"}[name]
            sandbox = "workspace-write" if name == "basix_pager" else "read-only"
            sandbox_marker = validator.SANDBOX_OVERRIDE + "\n" if name == "basix_pager" else ""
            model = "gpt-6-astra" if name == "basix_miraculix" else "gpt-6-luna"
            marker = validator.OVERRIDE + "\n" if name == "basix_miraculix" else ""
            directory, path = self.write_agent(name=name, level=wrong, effort=effort,
                                                model=model, marker=marker, sandbox=sandbox,
                                                sandbox_marker=sandbox_marker)
            with directory, self.assertRaisesRegex(validator.Invalid, "must use"):
                validator.validate_agent(path)

    def test_runtime_level_declaration_is_enforced(self):
        for level in ("junior", "senior", "principal"):
            directory, path = self.write_agent(level=level,
                                                principal_marker=level == "principal")
            text = path.read_text()
            text = text.replace(f"You are a {level} Basix agent.\n", "")
            path.write_text(text)
            with directory, self.assertRaises(validator.Invalid):
                validator.validate_agent(path)

    def test_concrete_spawn_permissions_are_rejected(self):
        for clause in validator.LEGACY_SPAWN_CLAUSES:
            directory, path = self.write_agent(preamble=f"{clause}\n")
            with directory, self.assertRaises(validator.Invalid):
                validator.validate_agent(path)

    def test_rejects_missing_duplicate_or_changed_bootstrap(self):
        directory, path = self.write_agent(block=False)
        with directory, self.assertRaisesRegex(validator.Invalid, "bootstrap markers"):
            validator.validate_agent(path)

        directory, path = self.write_agent()
        with directory:
            text = path.read_text()
            block = text[
                text.index(validator.BOOTSTRAP_START):
                text.index(validator.BOOTSTRAP_END) + len(validator.BOOTSTRAP_END)
            ]
            path.write_text(text.replace(block, f"{block}\n{block}"))
            with self.assertRaisesRegex(validator.Invalid, "bootstrap markers"):
                validator.validate_agent(path)

        directory, path = self.write_agent()
        with directory:
            path.write_text(path.read_text().replace(
                "Read the complete available `basix` router skill.",
                "Read an available router.",
            ))
            with self.assertRaisesRegex(validator.Invalid, "bootstrap block differs"):
                validator.validate_agent(path)

    def test_rejects_missing_management_or_contract_load_boundary(self):
        for phrase in (
            "Read the complete `basix-subagent-management` skill referenced by the router.",
            "Read completely the agent communication contract referenced by that skill.",
            "If the router, management skill, or contract cannot be read",
        ):
            with self.subTest(phrase=phrase):
                directory, path = self.write_agent()
                with directory:
                    path.write_text(path.read_text().replace(phrase, "Skip this source."))
                    with self.assertRaisesRegex(validator.Invalid, "bootstrap block differs"):
                        validator.validate_agent(path)

    def test_rejects_embedded_full_contract_copy(self):
        directory, path = self.write_agent()
        with directory:
            full_contract = CONTRACT_REFERENCE.read_text()
            path.write_text(path.read_text().replace(
                validator.BOOTSTRAP_END,
                f"{validator.BOOTSTRAP_END}\n{full_contract}",
            ))
            with self.assertRaisesRegex(validator.Invalid, "full communication contract"):
                validator.validate_agent(path)

    def test_xhigh_and_exceptional_max_are_valid_without_override(self):
        for effort in ("xhigh", "max"):
            directory, path = self.write_agent(effort=effort)
            with directory:
                validator.validate_agent(path)

    def test_description_requires_prefix_at_start(self):
        for description in ("Test agent", "Test Basix-Agent: agent"):
            directory, path = self.write_agent(description=description)
            with directory, self.assertRaisesRegex(validator.Invalid, "description must begin"):
                validator.validate_agent(path)

    def test_native_name_requires_basix_prefix(self):
        directory, path = self.write_agent(name="agent")
        with directory, self.assertRaisesRegex(validator.Invalid, "must begin with 'basix_'"):
            validator.validate_agent(path)

    def test_non_luna_requires_adjacent_override(self):
        directory, path = self.write_agent(model="custom")
        with directory, self.assertRaisesRegex(validator.Invalid, "override"):
            validator.validate_agent(path)
        directory, path = self.write_agent(model="custom", effort="extreme", marker=validator.OVERRIDE + "\n")
        with directory:
            validator.validate_agent(path)

    def test_default_effort_and_missing_bootstrap_rejected(self):
        directory, path = self.write_agent(effort="extreme")
        with directory, self.assertRaisesRegex(validator.Invalid, "effort"):
            validator.validate_agent(path)
        directory, path = self.write_agent(block=False)
        with directory, self.assertRaisesRegex(validator.Invalid, "markers"):
            validator.validate_agent(path)

    def test_rejects_shortened_or_changed_bootstrap(self):
        canonical = "Read the complete available `basix` router skill."
        for replacement in (canonical, "Read the available `basix` router skill."):
            directory, path = self.write_agent()
            text = path.read_text()
            if replacement == canonical:
                text = text.replace(replacement, "")
            else:
                text = text.replace(canonical, replacement)
            path.write_text(text)
            with directory, self.assertRaisesRegex(validator.Invalid, "differs from canonical"):
                validator.validate_agent(path)

    def test_requires_read_only_sandbox(self):
        for sandbox in ("workspace-write", "danger-full-access", ""):
            directory, path = self.write_agent(sandbox=sandbox)
            with directory, self.assertRaisesRegex(validator.Invalid, "sandbox_mode|workspace-write"):
                validator.validate_agent(path)

    def test_pager_xhigh_is_classified_and_workspace_write_needs_marker(self):
        directory, path = self.write_agent(name="basix_pager", effort="xhigh", sandbox="workspace-write")
        with directory, self.assertRaisesRegex(validator.Invalid, "sandbox override"):
            validator.validate_agent(path)

        directory, path = self.write_agent(
            name="basix_pager", effort="xhigh", sandbox="workspace-write",
            sandbox_marker=validator.SANDBOX_OVERRIDE + "\n",
        )
        with directory:
            validator.validate_agent(path)

        directory, path = self.write_agent(
            name="basix_pager", effort="xhigh", marker=validator.OVERRIDE + "\n",
            sandbox="workspace-write", sandbox_marker=validator.SANDBOX_OVERRIDE + "\n",
        )
        with directory, self.assertRaisesRegex(validator.Invalid, "without an override"):
            validator.validate_agent(path)

        for effort in ("high", "max"):
            directory, path = self.write_agent(
                name="basix_pager", effort=effort, sandbox="workspace-write",
                sandbox_marker=validator.SANDBOX_OVERRIDE + "\n",
            )
            with directory, self.assertRaisesRegex(validator.Invalid, "xhigh reasoning"):
                validator.validate_agent(path)

    def test_verifier_uses_classified_xhigh_without_override_and_read_only(self):
        directory, path = self.write_agent(name="basix_verifier", effort="xhigh")
        with directory:
            validator.validate_agent(path)
        directory, path = self.write_agent(name="basix_verifier", effort="xhigh", sandbox="workspace-write")
        with directory, self.assertRaisesRegex(validator.Invalid, "reserved for basix_pager|read-only"):
            validator.validate_agent(path)

        directory, path = self.write_agent(name="basix_verifier", effort="xhigh", marker=validator.OVERRIDE + "\n")
        with directory, self.assertRaisesRegex(validator.Invalid, "without an override"):
            validator.validate_agent(path)
        for effort in ("high", "max"):
            directory, path = self.write_agent(name="basix_verifier", effort=effort)
            with directory, self.assertRaisesRegex(validator.Invalid, "xhigh reasoning"):
                validator.validate_agent(path)

    def test_sandbox_override_is_reserved_for_pager(self):
        directory, path = self.write_agent(
            name="basix_agent", sandbox="workspace-write", sandbox_marker=validator.SANDBOX_OVERRIDE + "\n",
        )
        with directory, self.assertRaisesRegex(validator.Invalid, "reserved for basix_pager"):
            validator.validate_agent(path)

        directory, path = self.write_agent(
            name="basix_agent", sandbox_marker=validator.SANDBOX_OVERRIDE + "\n",
        )
        with directory, self.assertRaisesRegex(validator.Invalid, "reserved for basix_pager"):
            validator.validate_agent(path)

    def test_model_and_sandbox_fields_must_be_unique(self):
        directory, path = self.write_agent()
        path.write_text(path.read_text() + '\n[metadata]\nmodel = "gpt-6-luna"\n')
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
        with directory, self.assertRaisesRegex(validator.Invalid, "gpt-6-luna"):
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

    def test_miraculix_configuration_is_fixed(self):
        directory, path = self.write_agent(
            name="basix_miraculix", model="gpt-6-astra", effort="low",
            marker=validator.OVERRIDE + "\n",
        )
        with directory:
            validator.validate_agent(path)
        cases = (
            {"model": "gpt-6-luna", "marker": ""},
            {"model": "gpt-6-astra", "marker": ""},
            {"model": "gpt-6-astra", "effort": "medium", "marker": validator.OVERRIDE + "\n"},
        )
        for kwargs in cases:
            directory, path = self.write_agent(name="basix_miraculix", **kwargs)
            with directory, self.assertRaises(validator.Invalid):
                validator.validate_agent(path)


class RepositoryPolicyTests(unittest.TestCase):
    def test_native_agents_use_only_canonical_bootstrap_and_validate(self):
        repository = Path(__file__).resolve().parents[3]
        agents = sorted((repository / "src/agents/native").glob("*.toml"))
        self.assertTrue(agents)
        for path in agents:
            text = path.read_text()
            self.assertEqual(text.count(validator.BOOTSTRAP_START), 1, path)
            self.assertEqual(text.count(validator.BOOTSTRAP_END), 1, path)
            self.assertNotIn(validator.CONTRACT_START, text, path)
            self.assertTrue(tomllib.loads(text)["name"].startswith("basix_"), path)
            validator.validate_agent(path)

        contract = (repository / "src/skills/basix-subagent-management/references/agent-communication-contract.md").read_text()
        versions = re.findall(r"(?i)\bcontract(?:\s+version)?\s+(\d+\.\d+)\b", contract)
        self.assertTrue(versions)
        self.assertEqual(set(versions), {"2.0"})

    def test_schema_uses_contract_2_0_and_models_subagent_insights(self):
        schema = json.loads((ROOT / "references" / "message.schema.json").read_text())
        self.assertTrue(schema["$id"].endswith("agent-message-2.0.json"))
        self.assertEqual(schema["properties"]["contract_version"]["const"], "2.0")
        insights = schema["$defs"]["final_data"]["then"]["properties"]["subagent_insights"]
        self.assertEqual(insights["type"], "array")
        self.assertEqual(insights["minItems"], 1)
        self.assertIn("{0,23}", insights["items"]["pattern"])

    def test_skills_require_selective_repository_verification(self):
        repository = Path(__file__).resolve().parents[3]
        policies = (
            (
                repository / "src/skills/basix/SKILL.md",
                repository / "src/skills/basix/references/developing-basix.md",
            ),
            (repository / "src/skills/basix-agent-authoring/SKILL.md",),
        )
        for policy_files in policies:
            text = "\n".join(path.read_text() for path in policy_files)
            normalized = " ".join(text.split())
            self.assertRegex(normalized, r"select (?:tests|directly affected component tests)")
            self.assertIn("change", normalized)
            self.assertIn("dependen", normalized)
            self.assertIn("Run the selected test paths explicitly", normalized)
            self.assertIn("report each command together with the change it covers", normalized)
            self.assertRegex(
                normalized,
                r"Use\s+`\./test/verify-basix\.sh` only when",
            )
            self.assertRegex(
                normalized,
                r"use `\./test/test-setup\.sh` only when",
            )
            self.assertIn("Every test that is started must", normalized)
            self.assertIn("finish successfully", normalized)


class CliTests(unittest.TestCase):
    def test_unhashable_enum_values_are_controlled_invalid(self):
        """Malformed enum arrays/objects receive Invalid diagnostics through CLI."""
        for key in ("message_type", "status", "severity"):
            for value in ([], {}):
                message = ({**issue(), "errors": [{**error(), key: value}]}
                           if key == "severity" else {**final(1), key: value})
                with self.subTest(key=key, value=value):
                    result = self.run_cli("message", json.dumps(message))
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertTrue(result.stderr.startswith("invalid:"), result.stderr)
                    self.assertNotIn("Traceback", result.stderr)
        result = self.run_cli("message", json.dumps(issue()))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def run_cli(self, command, payload):
        return subprocess.run([sys.executable, str(SCRIPT), command, "--stdin"], input=payload,
                              text=True, capture_output=True, check=False)

    def test_message_stdin(self):
        result = self.run_cli("message", json.dumps(final(1)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "valid")

    def test_serialization_failure_is_not_a_delivery(self):
        result = self.run_cli("message", "{invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(result.stdout.strip(), "valid")

    def test_stream_is_json_lines_not_array(self):
        payload = "\n".join(json.dumps(value) for value in (issue(), final()))
        result = self.run_cli("stream", payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_cli("stream", json.dumps([issue(), final()]))
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()

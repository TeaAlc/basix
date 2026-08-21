#!/usr/bin/env python3
"""Deterministic compatibility and safety tests for container inspect policy."""

import copy
import importlib.util
import json
import pathlib
import types
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
POLICY = ROOT / "src/setup/scrapling-tor/container_policy.py"
FIXTURES = pathlib.Path(__file__).with_name("fixtures")
spec = importlib.util.spec_from_file_location("container_policy", POLICY)
policy = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(policy)


def fixture(name):
    return json.loads((FIXTURES / name).read_text())[0]


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.legacy = fixture("podman-legacy-stdio.json")

    def test_real_legacy_fixture_is_managed(self):
        self.assertTrue(policy.legacy(self.legacy, "/home/codex/.codex/basix/scrapling-tor/policy_mcp.py"))

    def test_unrelated_and_unsafe_are_distinct(self):
        benign = fixture("podman-benign-container.json")
        unsafe = fixture("podman-unsafe-scrapling.json")
        self.assertFalse(policy.scrapling_related(benign))
        self.assertTrue(policy.scrapling_related(unsafe))
        self.assertFalse(policy.legacy(unsafe, "/home/codex/.codex/basix/scrapling-tor/policy_mcp.py"))

    def test_sparse_inspect_fails_closed(self):
        sparse = {"Id": self.legacy["Id"]}
        self.assertFalse(policy.inspect_complete(sparse))

    def test_string_list_and_null_commands_normalize(self):
        self.assertEqual(policy.sequence("python"), ["python"])
        self.assertEqual(policy.sequence(["python"]), ["python"])
        self.assertEqual(policy.sequence(None), [])
        changed = copy.deepcopy(self.legacy)
        changed["Config"]["Entrypoint"] = ["/app/.venv/bin/python"]
        changed["Config"]["Cmd"] = "/opt/basix/policy_mcp.py"
        self.assertTrue(policy.legacy(changed, "/home/codex/.codex/basix/scrapling-tor/policy_mcp.py"))

    def test_managed_scrapling_requires_current_tor_gateway(self):
        current = fixture("podman-current-http.json")
        config = current["Config"]
        self.assertTrue(policy.proxy_env_valid(config, "8002", "10.89.1.2"))
        self.assertFalse(policy.proxy_env_valid(config, "8002", "10.89.1.99"))

    def test_each_security_invariant_blocks_migration(self):
        mutations = (
            lambda c: c["Config"]["Labels"].clear(),
            lambda c: c["NetworkSettings"]["Networks"].update({"host": {}}),
            lambda c: c["Config"]["Env"].remove("HTTP_PROXY=socks5h://10.89.1.1:9050"),
            lambda c: c["Mounts"][0].update(RW=True),
            lambda c: c["Config"].update(Entrypoint=["python"]),
            lambda c: c["Config"].update(Cmd=["other.py"]),
            lambda c: c["HostConfig"].update(Privileged=True),
            lambda c: c["HostConfig"].update(CapAdd=["SYS_ADMIN"]),
            lambda c: c["Config"].update(CreateCommand=["podman", "run"]),
            lambda c: c["HostConfig"].update(SecurityOpt=[]),
            lambda c: c["HostConfig"].update(PortBindings={"8000/tcp": [{"HostIp":"0.0.0.0","HostPort":"8000"}]}),
            lambda c: c["HostConfig"].update(AutoRemove=False),
            lambda c: c["HostConfig"].update(RestartPolicy={"Name":"always"}),
            lambda c: c["Config"].update(Image="docker.io/pyd4vinci/scrapling:latest"),
            lambda c: c["HostConfig"].update(SecurityOpt=["no-new-privileges=false"]),
            lambda c: c["Mounts"][0].update(Source="/tmp/evil/basix/scrapling-tor/policy_mcp.py"),
            lambda c: c.update(ImageName="docker.io/pyd4vinci/scrapling@sha256:" + "0" * 64),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                changed = copy.deepcopy(self.legacy)
                mutate(changed)
                self.assertFalse(policy.legacy(changed, "/home/codex/.codex/basix/scrapling-tor/policy_mcp.py"))


if __name__ == "__main__":
    unittest.main()

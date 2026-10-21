#!/usr/bin/env python3
"""Deterministic compatibility and safety tests for container inspect policy."""

import copy
import importlib.util
import json
import pathlib
from argparse import Namespace
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

    def test_cap_drop_count_does_not_prove_all_capabilities_were_dropped(self):
        changed = copy.deepcopy(self.legacy)
        changed["HostConfig"]["CapDrop"] = [f"CAP_CUSTOM_{index}" for index in range(10)]
        changed["EffectiveCaps"] = ["CAP_SYS_ADMIN"]
        changed["BoundingCaps"] = ["CAP_SYS_ADMIN"]
        self.assertFalse(
            policy.dropped_all(changed, changed["Config"], changed["HostConfig"])
        )

    def test_numeric_proxy_is_legacy_and_alias_proxy_is_canonical(self):
        current = fixture("podman-current-http.json")
        config = current["Config"]
        self.assertEqual(policy.proxy_env_kind(config, "8002"), "numeric-legacy")
        canonical = copy.deepcopy(config)
        canonical["Env"] = [
            item.replace("BASIX_TOR_IP=10.89.1.2", "BASIX_TOR_HOST=basix-tor-proxy")
            .replace("socks5h://10.89.1.2:9050", "socks5h://basix-tor-proxy:9050")
            for item in canonical["Env"]
        ]
        self.assertEqual(policy.proxy_env_kind(canonical, "8002"), "canonical")
        self.assertIsNone(policy.proxy_env_kind(canonical, "9123"))

    def test_numeric_legacy_proxy_must_be_private_ipv4(self):
        current = fixture("podman-current-http.json")
        for address in ("8.8.8.8", "999.999.999.999", "2001:db8::1"):
            changed = copy.deepcopy(current["Config"])
            changed["Env"] = [
                item.replace("10.89.1.2", address) for item in changed["Env"]
            ]
            with self.subTest(address=address):
                self.assertIsNone(policy.proxy_env_kind(changed, "8002"))

    def test_managed_scrapling_port_change_is_safe_drift(self):
        current = copy.deepcopy(fixture("podman-current-http.json"))
        current["Config"]["Env"] = [
            item.replace("BASIX_TOR_IP=10.89.1.2", "BASIX_TOR_HOST=basix-tor-proxy")
            .replace("socks5h://10.89.1.2:9050", "socks5h://basix-tor-proxy:9050")
            for item in current["Config"]["Env"]
        ]
        args = Namespace(
            kind="scrapling", configured=current["Config"]["Image"],
            actual=current["Image"], port="9123", policy="/tmp/codex/basix/scrapling-tor/policy_mcp.py",
            tor_host="basix-tor-proxy",
        )
        self.assertEqual(policy.managed(current, args), 10)

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


class SupervisorPolicyTests(unittest.TestCase):
    """Prove legacy migration and strict ownership of the new supervisor."""

    def setUp(self):
        """Prepare self's canonical alias service based on a real inspect fixture."""
        self.current = fixture("podman-current-http.json")
        self.current["Config"]["Env"] = [
            item.replace("BASIX_TOR_IP=10.89.1.2", "BASIX_TOR_HOST=basix-tor-proxy")
            .replace("socks5h://10.89.1.2:9050", "socks5h://basix-tor-proxy:9050")
            for item in self.current["Config"]["Env"]
        ]
        self.args = Namespace(kind="scrapling", configured=self.current["Config"]["Image"],
                              actual=self.current["Image"], port="8002",
                              policy="/tmp/codex/basix/scrapling-tor/policy_mcp.py", tor_host=policy.TOR_HOST)

    def supervised(self):
        """Return self's fixture with the exact canonical supervisor mount and probe."""
        current = copy.deepcopy(self.current)
        current["Config"]["Cmd"] = [policy.SUPERVISOR, "mcp"]
        current["Config"]["Healthcheck"] = {"Test": ["CMD-SHELL", f"{policy.PYTHON} {policy.SUPERVISOR} --probe mcp"]}
        current["Mounts"].append({"Source": "/tmp/codex/basix/scrapling-tor/service_supervisor.py", "Destination": policy.SUPERVISOR, "RW": False})
        return current

    def test_existing_managed_alias_service_is_replaceable(self):
        """Assert self's prior unsupervised canonical runtime is safe migration drift."""
        self.assertEqual(policy.managed(self.current, self.args), 10)
        self.assertEqual(policy.managed(self.supervised(), self.args), 0)

    def test_supervisor_mount_command_health_and_foreign_resources_fail_closed(self):
        """Reject each mutation of self's otherwise canonical supervisor resources."""
        mutations = (
            lambda c: c["Mounts"][1].update(RW=True),
            lambda c: c["Mounts"][1].update(Source="/tmp/foreign/service_supervisor.py"),
            lambda c: c["Mounts"].pop(),
            lambda c: c["Config"].update(Cmd=[policy.SUPERVISOR, "tor"]),
            lambda c: c["Config"].update(Healthcheck={"Test": ["CMD-SHELL", "true"]}),
            lambda c: c["NetworkSettings"]["Networks"].update({"host": {}}),
            lambda c: c["Config"]["Labels"].clear(),
        )
        for mutation in mutations:
            current = self.supervised()
            mutation(current)
            with self.subTest(mutation=mutation):
                self.assertEqual(policy.managed(current, self.args), 1)

    def test_tor_legacy_command_is_migrated_and_unknown_command_rejected(self):
        """Check self's Tor ownership requires known old or supervised commands."""
        current = copy.deepcopy(self.current)
        current["Mounts"] = []
        current["HostConfig"]["PortBindings"] = {}
        current["NetworkSettings"]["Networks"] = {policy.EGRESS: {}, policy.INTERNAL: {"Aliases": [policy.TOR_HOST]}}
        current["Config"]["Healthcheck"] = {"Test": ["CMD-SHELL", "grep -q 'Bootstrapped 100%' /var/log/tor/notices.log"]}
        self.args.kind = "tor"
        legitimate_forms = (
            (["tor", "-f", "/etc/tor/torrc"], []),
            (["tor"], ["-f", "/etc/tor/torrc"]),
        )
        for entrypoint, command in legitimate_forms:
            with self.subTest(entrypoint=entrypoint, command=command):
                current["Config"]["Entrypoint"] = entrypoint
                current["Config"]["Cmd"] = command
                self.assertEqual(policy.managed(current, self.args), 10)
                for field in ("Entrypoint", "Cmd"):
                    modified = copy.deepcopy(current)
                    modified["Config"][field].append("--SocksPort=0.0.0.0:9999")
                    self.assertEqual(policy.managed(modified, self.args), 1)
                modified = copy.deepcopy(current)
                modified["Config"]["Healthcheck"]["Test"] = ["CMD-SHELL", "true"]
                self.assertEqual(policy.managed(modified, self.args), 1)
        current["Config"]["Entrypoint"] = ["python3", policy.SUPERVISOR, "tor"]
        current["Config"]["Cmd"] = []
        current["Config"]["Healthcheck"]["Test"] = ["CMD-SHELL", f"python3 {policy.SUPERVISOR} --probe tor"]
        self.assertEqual(policy.managed(current, self.args), 0)
        current["Config"]["Entrypoint"] = ["sh", "-c", "sleep infinity"]
        self.assertEqual(policy.managed(current, self.args), 1)

    def test_podman_scalar_tor_entrypoint_requires_exact_executed_argv(self):
        """Check self's observed Podman serialization without accepting shell variations."""
        current = copy.deepcopy(self.current)
        observed = fixture("podman-supervised-tor-command.json")
        current["Config"].update(observed["Config"])
        current.update(Path=observed["Path"], Args=observed["Args"])
        current["Mounts"] = []
        current["HostConfig"]["PortBindings"] = {}
        current["NetworkSettings"]["Networks"] = {policy.EGRESS: {}, policy.INTERNAL: {"Aliases": [policy.TOR_HOST]}}
        self.args.kind = "tor"
        for argv, probe, expected in (
            (["python3", policy.SUPERVISOR, "tor"], f"python3 {policy.SUPERVISOR} --probe tor", 0),
            (["tor", "-f", "/etc/tor/torrc"], "grep -q 'Bootstrapped 100%' /var/log/tor/notices.log", 10),
        ):
            if expected == 10:
                current["Config"]["Entrypoint"] = " ".join(argv)
                current.update(Path=argv[0], Args=argv[1:])
            current["Config"]["Healthcheck"] = {"Test": ["CMD-SHELL", probe]}
            with self.subTest(argv=argv):
                self.assertEqual(policy.managed(current, self.args), expected)
                for command in (None, []):
                    modified = copy.deepcopy(current)
                    modified["Config"]["Cmd"] = command
                    self.assertEqual(policy.managed(modified, self.args), expected)
                for command in ({}, 0, False, "", ()):
                    modified = copy.deepcopy(current)
                    modified["Config"]["Cmd"] = command
                    with self.subTest(command=command):
                        self.assertEqual(policy.managed(modified, self.args), 1)
                mutations = (
                    lambda c: c["Config"].update(Entrypoint=c["Config"]["Entrypoint"] + " --extra"),
                    lambda c: c["Config"].update(Cmd=["--extra"]),
                    lambda c: c.update(Path="sh"),
                    lambda c: c["Args"].append("--extra"),
                    lambda c: c.pop("Path"),
                    lambda c: c.pop("Args"),
                    lambda c: c["Config"].update(Entrypoint='["' + '","'.join(argv) + '"]'),
                    lambda c: c["Config"].update(Entrypoint="  ".join(argv)),
                    lambda c: c["Config"]["Labels"].clear(),
                    lambda c: c["NetworkSettings"]["Networks"].update({"host": {}}),
                    lambda c: c["Mounts"].append({"Destination": "/tmp", "RW": True}),
                )
                for mutation in mutations:
                    modified = copy.deepcopy(current)
                    mutation(modified)
                    self.assertEqual(policy.managed(modified, self.args), 1)


if __name__ == "__main__":
    unittest.main()

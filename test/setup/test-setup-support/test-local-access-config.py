import importlib.util
import tomllib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location(
    "manage_developer_instructions", ROOT / "src/setup/lib/manage_developer_instructions.py"
)
helper = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(helper)


class LocalAccessConfigTests(unittest.TestCase):
    project_root = Path("/tmp/project with spaces\\and-backslash")

    def add(self, text="", local=True, socket=True):
        return helper.capability_add_text(text, self.project_root, local, socket)

    def test_all_combinations_are_parseable_and_idempotent(self):
        expected = {
            (True, False): "local-network",
            (False, True): "test-socket",
            (True, True): "local-network-test-socket",
        }
        for modes, profile in expected.items():
            with self.subTest(modes=modes):
                updated, status = self.add(local=modes[0], socket=modes[1])
                parsed = tomllib.loads(updated)
                self.assertEqual(status, "changed")
                self.assertEqual(parsed["default_permissions"], profile)
                self.assertEqual(
                    parsed["permissions"][profile]["network"]["unix_sockets"]
                    if modes[1]
                    else None,
                    {str(self.project_root / "test/test.sock"): "allow"}
                    if modes[1]
                    else None,
                )
                self.assertEqual(self.add(updated, *modes), (updated, "unchanged"))

    def test_socket_only_does_not_enable_local_network(self):
        updated, _ = self.add(local=False, socket=True)
        parsed = tomllib.loads(updated)
        self.assertNotIn("features", parsed)
        self.assertNotIn("domains", parsed["permissions"]["test-socket"]["network"])
        self.assertEqual(
            parsed["permissions"]["test-socket"]["network"]["unix_sockets"],
            {str(self.project_root / "test/test.sock"): "allow"},
        )

    def test_socket_only_rejects_foreign_network_proxy(self):
        for original in (
            "features.network_proxy = true\n",
            "[features]\nnetwork_proxy = false\n",
        ):
            with self.subTest(original=original):
                with self.assertRaises(helper.ConfigError):
                    self.add(original, local=False, socket=True)

    def test_switching_capabilities_is_selective(self):
        both, _ = self.add(local=True, socket=True)
        socket_only, status = self.add(both, local=False, socket=True)
        self.assertEqual(status, "changed")
        parsed = tomllib.loads(socket_only)
        self.assertEqual(parsed["default_permissions"], "test-socket")
        self.assertNotIn("features", parsed)
        local_only, _ = self.add(socket_only, local=True, socket=False)
        parsed = tomllib.loads(local_only)
        self.assertEqual(parsed["default_permissions"], "local-network")
        self.assertNotIn("unix_sockets", parsed["permissions"]["local-network"]["network"])

    def test_existing_tables_comments_and_bytes_survive_round_trip(self):
        fixtures = (
            "",
            "name = \"project\"\n",
            "name = \"project\"",
            "# comment\n[foreign]\nvalue = true\n",
            "[features]\nforeign = true\n",
            "[features]\nforeign = true",
            "features.foreign = true\n",
            "# comment\r\n[foreign]\r\nvalue = true\r\n",
            "# comment\r\n[foreign]\r\nvalue = true",
        )
        for original in fixtures:
            with self.subTest(original=repr(original)):
                updated, _ = self.add(original, local=True, socket=True)
                removed, status = helper.capability_remove_text(updated, self.project_root)
                self.assertEqual(status, "changed")
                self.assertEqual(removed, original)

    def test_dotted_features_assignment_is_preserved(self):
        original = "features.shell_tool = true\n"
        updated, _ = self.add(original, local=True, socket=False)
        parsed = tomllib.loads(updated)
        self.assertTrue(parsed["features"]["shell_tool"])
        self.assertTrue(parsed["features"]["network_proxy"])

    def test_legacy_playwright_block_migrates_only_when_exact(self):
        legacy, _ = helper.playwright_add_text("")
        migrated, status = self.add(legacy, local=True, socket=True)
        self.assertEqual(status, "changed")
        parsed = tomllib.loads(migrated)
        self.assertEqual(parsed["default_permissions"], "local-network-test-socket")
        self.assertNotIn("playwright", parsed["permissions"])
        self.assertEqual(
            parsed["permissions"]["local-network-test-socket"]["network"]["unix_sockets"],
            {str(self.project_root / "test/test.sock"): "allow"},
        )

        altered = legacy.replace('default_permissions = "playwright"', 'default_permissions = "workspace"')
        with self.assertRaises(helper.ConfigError):
            self.add(altered, local=True, socket=False)

    def test_foreign_overlap_and_damaged_markers_fail_closed(self):
        cases = (
            'default_permissions = "workspace"\n',
            "[features]\nnetwork_proxy = false\n",
            "[permissions.local-network]\nextends = \":workspace\"\n",
            "[permissions.test-socket.network.unix_sockets]\n\"/other.sock\" = \"allow\"\n",
            "# basix:local-access-default:start\n",
            "[broken\n",
        )
        for original in cases:
            with self.subTest(original=original):
                with self.assertRaises(helper.ConfigError):
                    self.add(original, local=True, socket=True)

    def test_remove_without_owned_settings_is_stable(self):
        original = "# foreign\n[permissions.other]\nvalue = true\n"
        self.assertEqual(helper.capability_remove_text(original, self.project_root), (original, "unchanged"))

    def test_disable_rejects_foreign_shared_permission_keys(self):
        cases = (
            'default_permissions = "workspace"\n',
            "[features]\nnetwork_proxy = false\n",
            "[permissions.local-network]\nextends = \":workspace\"\n",
        )
        for original in cases:
            with self.subTest(original=original):
                with self.assertRaises(helper.ConfigError):
                    helper.capability_remove_text(original, self.project_root)


if __name__ == "__main__":
    unittest.main()

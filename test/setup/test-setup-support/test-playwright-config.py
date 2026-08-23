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


class PlaywrightConfigTests(unittest.TestCase):
    def test_add_is_parseable_and_idempotent(self):
        updated, status = helper.playwright_add_text("")
        self.assertEqual(status, "changed")
        self.assertEqual(tomllib.loads(updated)["default_permissions"], "playwright")
        self.assertEqual(helper.playwright_add_text(updated), (updated, "unchanged"))

    def test_existing_tables_and_comments_survive_round_trip(self):
        original = "# keep\nname = \"project\"\n[features]\nfoo = 1\n\n[permissions.other]\nvalue = true\n"
        updated, _ = helper.playwright_add_text(original)
        parsed = tomllib.loads(updated)
        self.assertEqual(parsed["features"]["foo"], 1)
        self.assertEqual(parsed["permissions"]["other"]["value"], True)
        self.assertIn("# keep\nname = \"project\"", updated)
        removed, status = helper.playwright_remove_text(updated)
        self.assertEqual(status, "changed")
        self.assertEqual(removed, original)

    def test_add_remove_preserves_foreign_bytes_for_line_endings_and_layouts(self):
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
                updated, _ = helper.playwright_add_text(original)
                removed, _ = helper.playwright_remove_text(updated)
                self.assertEqual(removed, original)

    def test_developer_instruction_round_trip_preserves_crlf_and_no_final_newline(self):
        block = "<!-- basix:developer-instructions:start -->\nX\n<!-- basix:developer-instructions:end -->"
        fixtures = (
            'developer_instructions = "foreign"\r\n[foreign]\r\nvalue = true\r\n',
            'developer_instructions = "foreign"',
            'name = "project"',
            'name = "project"\r\n[foreign]\r\nvalue = true',
        )
        for original in fixtures:
            with self.subTest(original=repr(original)):
                updated, changed = helper.update_text(original, block, "add")
                self.assertTrue(changed)
                removed, removed_changed = helper.update_text(updated, "", "remove")
                self.assertTrue(removed_changed)
                self.assertEqual(removed, original)

    def test_dotted_features_assignment_is_supported(self):
        original = "features.shell_tool = true\n"
        updated, _ = helper.playwright_add_text(original)
        parsed = tomllib.loads(updated)
        self.assertTrue(parsed["features"]["shell_tool"])
        self.assertTrue(parsed["features"]["network_proxy"])

    def test_foreign_overlap_and_damaged_markers_fail_closed(self):
        cases = (
            'default_permissions = "workspace"\n',
            "[features]\nnetwork_proxy = false\n",
            "[permissions.playwright]\nextends = \"workspace\"\n",
            helper.PLAYWRIGHT_DEFAULT_BLOCK.replace('"playwright"', '"workspace"'),
        )
        for original in cases:
            with self.subTest(original=original):
                with self.assertRaises(helper.ConfigError):
                    helper.playwright_add_text(original)

    def test_owned_markers_in_foreign_table_fail_closed(self):
        managed, _ = helper.playwright_add_text("")
        relocated = "[foreign]\n" + managed
        with self.assertRaises(helper.ConfigError):
            helper.playwright_add_text(relocated)
        with self.assertRaises(helper.ConfigError):
            helper.playwright_remove_text(relocated)

    def test_remove_without_owned_settings_is_stable(self):
        original = "# foreign\n[permissions.other]\nvalue = true\n"
        self.assertEqual(helper.playwright_remove_text(original), (original, "unchanged"))

    def test_malformed_toml_is_rejected(self):
        with self.assertRaises(helper.ConfigError):
            helper.playwright_add_text("[broken\n")


if __name__ == "__main__":
    unittest.main()

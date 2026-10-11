"""Execute documented inventories against canonical and excluded evidence."""
import re
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path


class ExplorerScopeTests(unittest.TestCase):
    def test_conditional_inventory_and_fallback(self):
        repository = Path(__file__).resolve().parents[3]
        instructions = tomllib.loads(
            (repository / "src/agents/native/basix-file-explorer.toml").read_text()
        )["developer_instructions"]
        for obligation in (
            "Apply every active scope exclusion", "content searches",
            "When developing Basix itself", "These Basix-source exclusions",
            "in other projects, relevant canonical runtime configuration may",
        ):
            self.assertIn(obligation, instructions)
        inventories = re.findall(r"`(rg --files[^`]+)`", instructions)
        fallback = re.search(r"`(find \. [^`]+)`", instructions).group(1)
        self.assertEqual(len(inventories), 2)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in ("src/canonical.txt", ".codex/runtime.txt",
                             ".agents/runtime.txt", ".git/hidden.txt",
                             "nested/.agents/canonical.txt"):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("evidence\n")
            content_search = inventories[1].replace("--files", "-l evidence")
            for command in (*inventories, fallback, content_search):
                with self.subTest(command=command):
                    output = subprocess.run(command, shell=True, cwd=root, check=True,
                                            text=True, capture_output=True).stdout
                    paths = {line.removeprefix("./") for line in output.splitlines()}
                    self.assertIn("src/canonical.txt", paths)
                    self.assertIn("nested/.agents/canonical.txt", paths)
                    self.assertNotIn(".git/hidden.txt", paths)
                    expected_runtime = command == inventories[0]
                    self.assertEqual(".codex/runtime.txt" in paths, expected_runtime)
                    self.assertEqual(".agents/runtime.txt" in paths, expected_runtime)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
manifest = json.loads((root / "src/plugin/plugin.json").read_text())
assert manifest["name"] == "basix" and manifest["skills"] == "./skills/"
market = json.loads((root / "src/plugin/marketplace.json").read_text())
assert market["plugins"][0]["source"] == {"source": "local", "path": "./"}
for path in sorted((root / "src/skills").glob("*/SKILL.md")):
    match = re.search(r"(?m)^description:\s*(.+)$", path.read_text())
    assert match and match.group(1).strip().strip("\"'").startswith("Basix-Skill: "), path
router = (root / "src/skills/basix/SKILL.md").read_text()
router_flat = " ".join(router.split())
assert "sole runtime copy of Contract 1.4" in router
assert "maintaining, extending, testing, reviewing, or verifying" in router_flat
assert "[developing-basix.md](references/developing-basix.md) completely" in router_flat
assert "Do not load that reference merely because" in router_flat
development = (root / "src/skills/basix/references/developing-basix.md").read_text()
development_flat = " ".join(development.split())
assert "select tests" in development_flat and "changed components and their dependents" in development_flat
assert "Run the selected test paths explicitly" in development_flat
assert "report each command together with the change it covers" in development_flat
assert "`./test/verify-basix.sh` only when" in development_flat
assert "`./test/test-setup.sh` only when" in development_flat
assert "Every test that is started must" in development_flat and "finish successfully" in development_flat
for moved in ("src/agents", "repository-local `.codex/`", "reusable task workflows", "configure-tmux suite"):
    assert moved in development and moved not in router, moved
contract = (root / "src/skills/basix/references/agent-communication-contract.md").read_text()
assert "version=1.4" in contract and "communicates exclusively with its direct spawning parent" in contract
assert not list((root / "src").glob("**/tests"))
print("ok - basix metadata, router, development guidance, contract, and test layout")
PY

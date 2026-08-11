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
assert "select tests" in router_flat and "changed components and their dependents" in router_flat
assert "Run the selected test paths explicitly" in router_flat
assert "report each command together with the change it covers" in router_flat
assert "`./test/verify-basix.sh` only when" in router_flat
assert "`./test/test-setup.sh` only when" in router_flat
assert "Every test that is started must" in router_flat and "finish successfully" in router_flat
contract = (root / "src/skills/basix/references/agent-communication-contract.md").read_text()
assert "version=1.4" in contract and "communicates exclusively with its direct spawning parent" in contract
assert not list((root / "src").glob("**/tests"))
print("ok - basix metadata, router, contract, and test layout")
PY

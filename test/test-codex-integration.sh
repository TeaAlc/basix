#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 "$ROOT/test/test-scrapling-policy.py"
python3 - "$ROOT" <<'PY'
import sys
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
pager = tomllib.loads((root / "src/agents/native/basix-pager.toml").read_text())
assert pager["name"] == "basix_pager"
assert pager["model"] == "gpt-5.6-luna" and pager["model_reasoning_effort"] == "max"
assert pager["sandbox_mode"] == "workspace-write"
assert all(f"`{profile}`" in pager["developer_instructions"] for profile in ("ui_ux", "frontend", "backend_web", "fullstack", "integration"))
verifier = tomllib.loads((root / "src/agents/native/basix-verifier.toml").read_text())
assert verifier["name"] == "basix_verifier"
assert verifier["model"] == "gpt-5.6-luna" and verifier["model_reasoning_effort"] == "max"
assert verifier["sandbox_mode"] == "read-only"
assert "cycle_revision" in verifier["developer_instructions"]
print("ok - Codex integration sees canonical pager and verifier definitions")
PY

# Lifecycle operations are intentionally opt-in: this test may only manipulate
# resources created under its own isolated CODEX_HOME and unique runtime names.
if [[ ${BASIX_SCRAPLING_LIVE_TEST:-0} != 1 ]]; then
  printf 'ok - policy integration passed; live container lifecycle not requested\n'
  exit 0
fi
command -v codex >/dev/null
command -v podman >/dev/null
printf 'Live lifecycle must be run through the dedicated disposable-resource harness.\n' >&2
exit 2

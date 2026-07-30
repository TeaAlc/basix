#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for script in "$ROOT"/scripts/*.sh "$ROOT"/setup/*.sh "$ROOT"/setup/lib/*.sh "$ROOT"/tests/*.sh; do bash -n "$script"; done
python3 - "$ROOT" <<'PY'
import json, re, sys, tomllib
from pathlib import Path
root = Path(sys.argv[1])
manifest = json.loads((root / ".codex-plugin/plugin.json").read_text())
assert manifest["name"] == "basix" and manifest["version"] == "0.1.0"
assert manifest["skills"] == "./skills/" and "agents" not in manifest
market = json.loads((root / ".agents/plugins/marketplace.json").read_text())
assert market["name"] == "basix-local"
assert market["plugins"][0]["source"] == {"source": "local", "path": "./"}
skill_paths = sorted((root / "skills").glob("*/SKILL.md"))
assert skill_paths
for path in skill_paths:
    text = path.read_text()
    match = re.search(r"(?m)^description:\s*(.+)$", text)
    assert match and match.group(1).startswith("Basix-Skill: "), path
    ui = path.parent / "agents/openai.yaml"
    if ui.exists():
        match = re.search(r'(?m)^\s*short_description:\s*["\']?(Basix-Skill: .+?)["\']?\s*$', ui.read_text())
        assert match, ui
for path in sorted((root / "agents/native").glob("*.toml")):
    agent = tomllib.loads(path.read_text())
    assert agent["description"].startswith("Basix-Agent: "), path
assert not (root / "agents/exec").exists()
PY
VALIDATOR="$ROOT/skills/basix-agent-authoring/scripts/validate.py"
PYTHONPYCACHEPREFIX=${TMPDIR:-/tmp}/basix-pycache python3 -m py_compile "$ROOT/setup/lib/manage_developer_instructions.py" "$VALIDATOR"
python3 "$VALIDATOR" agent "$ROOT"/agents/native/*.toml
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$ROOT/skills/basix-agent-authoring/tests" -p 'test_*.py'
if command -v shellcheck >/dev/null; then shellcheck --severity=warning "$ROOT"/scripts/*.sh "$ROOT"/setup/*.sh "$ROOT"/setup/lib/*.sh "$ROOT"/tests/*.sh; else printf 'SKIP: shellcheck not installed\n'; fi
printf 'Static Basix verification passed.\n'

if command -v codex >/dev/null; then
  temp=$(mktemp -d)
  trap 'rm -rf "$temp"' EXIT
  mkdir -p "$temp/codex-home"
  CODEX_HOME="$temp/codex-home" codex plugin marketplace add "$ROOT" --json >/dev/null
  CODEX_HOME="$temp/codex-home" codex plugin add basix@basix-local --json >/dev/null
  CODEX_HOME="$temp/codex-home" codex plugin remove basix@basix-local --json >/dev/null
  CODEX_HOME="$temp/codex-home" codex plugin marketplace remove basix-local --json >/dev/null
  printf 'Real Codex plugin compatibility passed (no model run).\n'
else
  printf 'SKIP: codex CLI not installed\n'
fi

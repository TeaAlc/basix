#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/test/lib/run-agent-check.py" "$ROOT/src/agents/native/basix-researcher.toml" basix_researcher medium read-only
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
import sys
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
agent = tomllib.loads((root / 'src/agents/native/basix-researcher.toml').read_text())
instructions = ' '.join(agent['developer_instructions'].split())
# Read-only researchers route collection to the writer, despite discoverable tools.
assert 'load the complete `basix-scrapling` skill' in instructions
assert 'do not invoke `download_start`, `download_cancel` or `artifact_export`' in instructions
assert 'do not write files' in instructions
assert 'Request binary collection through an authorized writable parent' in instructions
assert 'Only inspect `download_status` or `artifact_info` when the same-owner capability is deliberately shared and inspection is authorized' in instructions
assert 'no fallback or service repair' in instructions
# Keep source research integration intact while adding the acquisition boundary.
assert '`source_observations`' in instructions and '`research_coverage`' in instructions
skill = root / 'src/skills/basix-scrapling/SKILL.md'
assert skill.is_file()
assert '| `basix-scrapling` |' in (root / 'README.md').read_text()
print('ok - researcher acquisition authority and skill integration')
PY

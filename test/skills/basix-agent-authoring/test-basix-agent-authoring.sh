#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/src/skills/basix-agent-authoring/scripts/validate.py" agent "$ROOT"/src/agents/native/*.toml
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$ROOT/test/skills/basix-agent-authoring" -p "test*.py"

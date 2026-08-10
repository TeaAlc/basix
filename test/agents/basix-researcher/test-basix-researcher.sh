#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/test/lib/run-agent-check.py" "$ROOT/src/agents/native/basix-researcher.toml" basix_researcher medium read-only
grep -Fq 'Scrapling' "$ROOT/src/agents/native/basix-researcher.toml"

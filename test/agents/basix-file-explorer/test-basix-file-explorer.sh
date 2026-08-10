#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/test/lib/run-agent-check.py" "$ROOT/src/agents/native/basix-file-explorer.toml" basix_file_explorer low read-only
grep -Fq 'read-only' "$ROOT/src/agents/native/basix-file-explorer.toml"
bash -n "$ROOT/src/scripts/run-file-explorer-benchmark.sh"

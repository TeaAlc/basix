#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/test/lib/run-agent-check.py" "$ROOT/src/agents/native/basix-verifier.toml" basix_verifier xhigh read-only
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/test/agents/basix-verifier/test_verifier_smoke.py"

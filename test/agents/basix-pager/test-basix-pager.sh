#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/test/lib/run-agent-check.py" "$ROOT/src/agents/native/basix-pager.toml" basix_pager xhigh workspace-write
for profile in ui_ux frontend backend_web fullstack integration; do grep -Fq "\`$profile\`" "$ROOT/src/agents/native/basix-pager.toml"; done
bash -n "$ROOT/src/scripts/run-pager-smoke.sh"

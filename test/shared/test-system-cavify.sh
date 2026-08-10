#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT/src/scripts" python3 "$ROOT/test/shared/test_system_cavify.py"

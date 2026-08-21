#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
bash -n "$ROOT/src/setup/install-scrapling-codex.sh" "$ROOT/src/setup/scrapling-tor/launcher.sh"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/test/setup/install-scrapling-codex/test_container_policy.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/test/setup/install-scrapling-codex/test_health_check.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/test/setup/install-scrapling-codex/test_scrapling_policy.py"
"$ROOT/test/setup/install-scrapling-codex/test-installer.sh"

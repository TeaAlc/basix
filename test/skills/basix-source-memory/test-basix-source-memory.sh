#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/test/skills/basix-source-memory/test_source_memory.py"

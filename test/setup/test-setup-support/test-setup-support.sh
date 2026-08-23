#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
bash -n "$ROOT/src/setup/lib/common.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/src/setup/lib/manage_developer_instructions.py" add --config "$tmp/config.toml" --instructions "$ROOT/src/setup/developer_instruction.md" >/dev/null
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/src/setup/lib/manage_developer_instructions.py" remove --config "$tmp/config.toml" --remove-empty-file >/dev/null
[[ ! -e $tmp/config.toml ]]
printf 'ok - setup support round trip\n'
"$ROOT/test/setup/test-setup-support/test-local-access-config.sh"

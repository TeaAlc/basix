#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
command -v codex >/dev/null || {
  printf 'error: codex CLI is required for the live plugin compatibility test\n' >&2
  exit 1
}
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
mkdir -p "$case_dir/codex-home" "$case_dir/work"
(
  cd "$case_dir/work"
  CODEX_HOME="$case_dir/codex-home" "$ROOT/src/setup/install_as_plugin.sh" >/dev/null
  CODEX_HOME="$case_dir/codex-home" "$ROOT/src/setup/install_as_plugin.sh" --uninstall >/dev/null
)
printf 'ok - live Codex plugin install and uninstall compatibility\n'

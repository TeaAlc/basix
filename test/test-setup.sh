#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
suites=(
  test/setup/install-for-project/test-install-for-project.sh
  test/setup/install-as-plugin/test-install-as-plugin.sh
  test/setup/install-ory-lumen/test-install-ory-lumen.sh
  test/setup/install-scrapling-codex/test-install-scrapling-codex.sh
  test/setup/test-setup-support/test-setup-support.sh
)
failed=()
for suite in "${suites[@]}"; do
  started=$SECONDS
  printf '\n==> %s\n' "$suite"
  if "$ROOT/$suite"; then status=PASS; else status=FAIL; failed+=("$suite"); fi
  printf '<== %s %s (%ss)\n' "$status" "$suite" "$((SECONDS-started))"
done
if ((${#failed[@]})); then
  printf '\nFailed suites:\n' >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi
printf '\nAll deterministic setup suites passed.\n'

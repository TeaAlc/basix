#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
suites=(
  test/agents/basix-file-explorer/test-basix-file-explorer.sh
  test/agents/basix-researcher/test-basix-researcher.sh
  test/agents/basix-pager/test-basix-pager.sh
  test/agents/basix-verifier/test-basix-verifier.sh
  test/skills/basix/test-basix.sh
  test/skills/basix/test-basix-static.sh
  test/skills/basix-agent-authoring/test-basix-agent-authoring.sh
  test/skills/basix-experience/test-basix-experience.sh
  test/shared/test-system-cavify.sh
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
printf '\nAll deterministic Basix suites passed.\n'

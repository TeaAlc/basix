#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RUNNER="$ROOT/src/scripts/run-quality-gates.sh"
PROFILE="$ROOT/src/scripts/quality-gates/basix.sh"
CUSTOM_PROFILE="$ROOT/src/scripts/quality-gates/custom.sh"
tmp=$(mktemp -d)
untracked="$ROOT/src/docs/.quality-gate-trailing.txt"
trap 'rm -rf "$tmp" "$untracked" "$CUSTOM_PROFILE"' EXIT

bash -n "$RUNNER" "$PROFILE"
[[ -x $RUNNER && -x $PROFILE ]]
help=$($RUNNER --help)
grep -Fq -- '--impact CLASS' <<<"$help"
grep -Fq -- '--log-dir DIR' <<<"$help"
grep -Fq -- '--immutable FILE=SHA256' <<<"$help"

dry=$($RUNNER --changed-file src/setup/developer_instruction.md --dry-run)
grep -Fq 'selected=scope diff-check static-policy managed-roundtrip' <<<"$dry"
grep -Fq 'review-required=independent frozen review' <<<"$dry"
if grep -Fq 'basix-aggregate' <<<"$dry"; then exit 1; fi
if grep -Fq 'setup-aggregate' <<<"$dry"; then exit 1; fi

component=$($RUNNER --changed-file src/skills/basix-experience/SKILL.md --dry-run)
grep -Fq 'basix-aggregate' <<<"$component"

aggregate=$($RUNNER --changed-file test/verify-basix.sh --dry-run)
grep -Fq 'basix-aggregate' <<<"$aggregate"
setup_aggregate=$($RUNNER --changed-file test/test-setup.sh --dry-run)
grep -Fq 'setup-aggregate' <<<"$setup_aggregate"

configure=$($RUNNER --changed-file src/skills/configure-tmux/SKILL.md --dry-run)
grep -Fq 'configure-tmux' <<<"$configure"
if grep -Fq 'basix-aggregate' <<<"$configure"; then exit 1; fi

scrapling=$($RUNNER --changed-file src/setup/install-scrapling-codex.sh --dry-run)
grep -Fq 'setup-aggregate' <<<"$scrapling"
grep -Fq 'scrapling-release' <<<"$scrapling"

normative=$($RUNNER --changed-file src/skills/basix/references/developing-basix.md --dry-run)
grep -Fq 'review-required=independent frozen review' <<<"$normative"

setup=$($RUNNER --changed-file src/setup/lib/manage_developer_instructions.py --dry-run)
grep -Fq 'managed-roundtrip' <<<"$setup"
grep -Fq 'setup-aggregate' <<<"$setup"

set +e
$RUNNER --changed-file .gitignore --dry-run >"$tmp/unknown.out" 2>"$tmp/unknown.err"
status=$?
set -e
[[ $status -eq 2 ]]
grep -Fq 'require an explicit --impact' "$tmp/unknown.err"

set +e
$RUNNER --changed-file .basix/memory.toml --dry-run >"$tmp/basix.out" 2>"$tmp/basix.err"
status=$?
set -e
[[ $status -eq 2 ]]
grep -Fq 'quality-gate scope excludes .basix paths' "$tmp/basix.err"

set +e
$RUNNER \
  --changed-file src/docs/architecture.md \
  --immutable ".basix/memory.toml=0000000000000000000000000000000000000000000000000000000000000000" \
  --dry-run >"$tmp/basix-immutable.out" 2>"$tmp/basix-immutable.err"
status=$?
set -e
[[ $status -eq 2 ]]
grep -Fq 'quality-gate scope excludes .basix paths' "$tmp/basix-immutable.err"

docs=$($RUNNER --changed-file src/docs/architecture.md --impact docs --log-dir "$tmp/docs-logs")
grep -Fq 'selected=scope diff-check' <<<"$docs"
grep -Fq 'all automated gates passed' <<<"$docs"
if grep -Fq 'All deterministic' <<<"$docs"; then exit 1; fi
[[ -s $tmp/docs-logs/scope.log ]]
[[ -e $tmp/docs-logs/diff-check.log ]]

hash=$(sha256sum "$ROOT/src/setup/developer_instruction.md" | awk '{print $1}')
printf 'review result: pass\n' >"$tmp/review.txt"
policy=$($RUNNER \
  --changed-file src/setup/developer_instruction.md \
  --immutable "src/setup/developer_instruction.md=$hash" \
  --review-evidence "$tmp/review.txt" \
  --log-dir "$tmp/policy-logs")
grep -Fq 'static-policy' <<<"$policy"
grep -Fq 'managed-roundtrip' <<<"$policy"
grep -Fq 'all automated gates passed' <<<"$policy"

set +e
$RUNNER \
  --changed-file src/docs/architecture.md \
  --impact docs \
  --immutable "src/setup/developer_instruction.md=0000000000000000000000000000000000000000000000000000000000000000" \
  --log-dir "$tmp/failure-logs" >"$tmp/failure.out" 2>"$tmp/failure.err"
status=$?
set -e
[[ $status -eq 4 ]]
grep -Fq 'immutable target changed before gates' "$tmp/failure.err"

set +e
$RUNNER \
  --changed-file src/docs/architecture.md \
  --immutable "src/setup/developer_instruction.md=bad" \
  --dry-run >"$tmp/bad-immutable.out" 2>"$tmp/bad-immutable.err"
status=$?
set -e
[[ $status -eq 2 ]]
grep -Fq 'immutable hash must be 64 hexadecimal characters' "$tmp/bad-immutable.err"

printf 'bad trailing  \n' >"$untracked"
set +e
$RUNNER --changed-file src/docs/.quality-gate-trailing.txt --impact docs --log-dir "$tmp/untracked-logs" >"$tmp/untracked.out" 2>"$tmp/untracked.err"
status=$?
set -e
[[ $status -eq 1 ]]
grep -Fq 'trailing whitespace' "$tmp/untracked-logs/diff-check.log"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'QG_PROFILE_NAME=custom' \
  'QG_PROFILE_IMPACTS=(smoke)' \
  'QG_PROFILE_GATES=(smoke-gate)' \
  'qg_reset_classification() { QG_KNOWN=0; QG_REQUIRED_GATES=(); QG_REVIEW_REQUIRED=0; }' \
  'qg_classify_path() { qg_reset_classification; QG_KNOWN=1; QG_REQUIRED_GATES=(smoke-gate); }' \
  "qg_apply_impact() { [[ \$1 == smoke ]] || return 2; QG_REQUIRED_GATES=(smoke-gate); }" \
  "qg_gate_command() { [[ \$1 == smoke-gate ]] || return 2; QG_COMMAND=(bash -c 'printf custom-gate\\\\n'); }" \
  "qg_gate_reason() { [[ \$1 == smoke-gate ]] || return 2; printf 'custom profile gate'; }" \
  >"$CUSTOM_PROFILE"
custom=$($RUNNER --profile custom --changed-file src/docs/architecture.md --impact smoke --dry-run)
grep -Fq 'selected=scope diff-check smoke-gate' <<<"$custom"
custom_run=$($RUNNER --profile custom --changed-file src/docs/architecture.md --impact smoke --log-dir "$tmp/custom-logs")
grep -Fq 'PASS smoke-gate' <<<"$custom_run"

printf 'ok - quality-gate selection, fail-closed scope, logging, and frozen evidence\n'

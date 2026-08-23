#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/src
case_dir=$(mktemp -d); trap 'rm -rf "$case_dir"' EXIT
passes=0 failures=0
ok() { printf 'ok - %s\n' "$1"; passes=$((passes+1)); }
bad() { printf 'not ok - %s\n' "$1"; failures=$((failures+1)); }
check() { local label=$1; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }
mock="$case_dir/bin"; mkdir -p "$mock"
cat >"$mock/codex" <<'SH'
#!/usr/bin/env bash
case "$*" in *'plugin marketplace list'*|*'plugin list'*) printf '[]\n' ;; *) printf '{}\n' ;; esac
SH
chmod +x "$mock/codex"; export PATH="$mock:$PATH"

project="$case_dir/project"
first_output=$("$ROOT/setup/install_for_project.sh" "$project" --no-local-network --no-test-socket)
if [[ -f $project/.agents/skills/basix/SKILL.md && -f $project/.agents/skills/basix/references/agent-communication-contract.md && -f $project/.agents/skills/basix-experience/scripts/collect-token-usage.py && -f $project/.codex/basix/agents/basix-researcher.toml ]] &&
   [[ ! -e $project/.basix ]] &&
   ! find "$project/.agents/skills" "$project/.codex/basix" -type l -print -quit | grep -q . &&
   ! cut -f1 "$project/.codex/.basix-install-state" | grep -Ev '^(copy|dircopy|dirfile)$' | grep -q .; then ok 'fresh project install copies complete trees without ADR artifacts'; else bad 'fresh project install copies complete trees without ADR artifacts'; fi
for agent in "$ROOT"/agents/native/*.toml; do
  check "project install reports $(basename "$agent") as installed" grep -Fq "$(basename "$agent") — installed" <<<"$first_output"
done
check 'project install preserves token collector bytes' cmp -s "$ROOT/skills/basix-experience/scripts/collect-token-usage.py" "$project/.agents/skills/basix-experience/scripts/collect-token-usage.py"
for agent in "$ROOT"/agents/native/*.toml; do
  check "project install preserves $(basename "$agent") bytes" cmp -s "$agent" "$project/.codex/basix/agents/$(basename "$agent")"
done
before=$(sha256sum "$project/.codex/.basix-install-state" "$project/.codex/config.toml")
second_output=$("$ROOT/setup/install_for_project.sh" "$project" --no-local-network --no-test-socket)
for agent in "$ROOT"/agents/native/*.toml; do
  check "project reinstall reports $(basename "$agent") as unchanged" grep -Fq "$(basename "$agent") — unchanged" <<<"$second_output"
done
check 'project reinstall is idempotent' test "$before" = "$(sha256sum "$project/.codex/.basix-install-state" "$project/.codex/config.toml")"

source_copy="$case_dir/source"; cp -R "$ROOT" "$source_copy"; update="$case_dir/update"
"$source_copy/setup/install_for_project.sh" "$update" --no-local-network --no-test-socket >/dev/null
printf '\ncopy-update\n' >>"$source_copy/skills/basix/SKILL.md"
printf '\n# report-update\n' >>"$source_copy/agents/native/basix-pager.toml"
update_output=$("$source_copy/setup/install_for_project.sh" "$update" --no-local-network --no-test-socket)
check 'project reinstall reports changed agent as updated' grep -Fq 'basix-pager.toml — updated' <<<"$update_output"
check 'reinstall synchronizes source updates' grep -Fq copy-update "$update/.agents/skills/basix/SKILL.md"
for agent in "$source_copy"/agents/native/*.toml; do
  check "project reinstall preserves $(basename "$agent") bytes" cmp -s "$agent" "$update/.codex/basix/agents/$(basename "$agent")"
done
stale_source="$source_copy/skills/basix/references/agent-communication-contract.md"
stale_target="$update/.agents/skills/basix/references/agent-communication-contract.md"
rm -- "$stale_source"; "$source_copy/setup/install_for_project.sh" "$update" --no-local-network --no-test-socket >/dev/null
check 'reinstall removes deleted manifest files' test ! -e "$stale_target"

dry="$case_dir/dry"; "$ROOT/setup/install_for_project.sh" "$dry" --dry-run --no-local-network --no-test-socket >/dev/null
check 'project dry-run is mutation-free' test ! -e "$dry"

changed="$case_dir/changed"; "$ROOT/setup/install_for_project.sh" "$changed" --no-local-network --no-test-socket >/dev/null
printf '\nlocal-change\n' >>"$changed/.agents/skills/basix/SKILL.md"; printf 'foreign\n' >"$changed/.agents/skills/basix/foreign.txt"; mkdir "$changed/.agents/skills/basix/foreign-empty"
"$ROOT/setup/install_for_project.sh" "$changed" --uninstall >/dev/null
if grep -Fq local-change "$changed/.agents/skills/basix/SKILL.md" && [[ -f $changed/.agents/skills/basix/foreign.txt && -d $changed/.agents/skills/basix/foreign-empty ]]; then ok 'uninstall preserves local and foreign content'; else bad 'uninstall preserves local and foreign content'; fi

clean="$case_dir/clean"; "$ROOT/setup/install_for_project.sh" "$clean" --no-local-network --no-test-socket >/dev/null; "$ROOT/setup/install_for_project.sh" "$clean" --uninstall >/dev/null
check 'clean uninstall removes payload state' test ! -e "$clean/.codex/.basix-install-state" -a ! -e "$clean/.agents/skills/basix" -a ! -e "$clean/.codex/basix"

foreign="$case_dir/foreign"; mkdir -p "$foreign/.agents/skills/basix"; printf x >"$foreign/.agents/skills/basix/foreign"
if "$ROOT/setup/install_for_project.sh" "$foreign" --no-local-network --no-test-socket >/dev/null 2>&1; then bad 'foreign directory is rejected'; else ok 'foreign directory is rejected'; fi
linked="$case_dir/linked"; mkdir -p "$linked/.agents/skills" "$case_dir/link-target"; ln -s "$case_dir/link-target" "$linked/.agents/skills/basix"
if "$ROOT/setup/install_for_project.sh" "$linked" --no-local-network --no-test-socket >/dev/null 2>&1; then bad 'directory symlink is rejected'; else ok 'directory symlink is rejected'; fi
alias="$case_dir/alias"; mkdir -p "$alias/.agents/skills"; ln -s "$ROOT/skills/basix" "$alias/.agents/skills/basix"
if "$ROOT/setup/install_for_project.sh" "$alias" --no-local-network --no-test-socket >/dev/null 2>&1; then bad 'physical source alias is rejected'; else ok 'physical source alias is rejected'; fi

for option in --mode --force --install-lumen --lumen-index; do
  if "$ROOT/setup/install_for_project.sh" "$case_dir/reject" "$option" value --no-local-network --no-test-socket >/dev/null 2>&1; then bad "project rejects $option"; else ok "project rejects $option"; fi
done


printf '%d passed, %d failed\n' "$passes" "$failures"; ((failures == 0))

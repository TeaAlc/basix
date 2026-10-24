#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/src
case_dir=$(mktemp -d); trap 'rm -rf "$case_dir"' EXIT
passes=0 failures=0
ok() { printf 'ok - %s\n' "$1"; passes=$((passes+1)); }
bad() { printf 'not ok - %s\n' "$1"; failures=$((failures+1)); }
check() { local label=$1; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }
state_targets_are_relative() {
  local state=$1
  [[ -s $state ]] || return 1
  awk -F '\t' '$1 ~ /^(copy|dircopy|dirfile)$/ {count++; if ($2 ~ /^\//) bad=1} END {exit (count == 0 || bad)}' "$state"
}
foreign_files_are_preserved() {
  grep -Fxq 'keep me' "$1" && grep -Fxq 'foreign config sibling' "$2"
}
mock="$case_dir/bin"; mkdir -p "$mock"
cat >"$mock/codex" <<'SH'
#!/usr/bin/env bash
case "$*" in *'plugin marketplace list'*|*'plugin list'*) printf '[]\n' ;; *) printf '{}\n' ;; esac
SH
chmod +x "$mock/codex"; export PATH="$mock:$PATH"

project="$case_dir/project"
first_output=$("$ROOT/setup/install_for_project.sh" "$project" --no-local-network --no-test-socket)
if [[ -f $project/.agents/skills/basix/SKILL.md && -f $project/.agents/skills/basix-subagent-management/references/agent-communication-contract.md && -f $project/.agents/skills/basix-experience/scripts/collect-token-usage.py && -f $project/.codex/basix/agents/basix-researcher.toml ]] &&
   [[ ! -e $project/.basix ]] &&
   ! find "$project/.agents/skills" "$project/.codex/basix" -type l -print -quit | grep -q . &&
   ! cut -f1 "$project/.codex/.basix-install-state" | grep -Ev '^(copy|dircopy|dirfile)$' | grep -q .; then ok 'fresh project install copies complete trees without ADR artifacts'; else bad 'fresh project install copies complete trees without ADR artifacts'; fi
for skill in basix-subagent-management basix-planning basix-adr basix-agent-memory basix-source-memory; do
  check "project install preserves $skill tree" diff -r "$ROOT/skills/$skill" "$project/.agents/skills/$skill"
done
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

renamed_source="$case_dir/rename-source"
"$ROOT/setup/install_for_project.sh" "$renamed_source" --no-local-network --no-test-socket >/dev/null
printf 'keep me\n' >"$renamed_source/foreign.keep"
mkdir -p "$renamed_source/.codex"
printf 'foreign config sibling\n' >"$renamed_source/.codex/foreign.toml"
mkdir -p "$renamed_source/.basix/sources"
printf 'version = 1\n# project source knowledge\n' >"$renamed_source/.basix/sources/sources.toml"
printf 'version = 1\n# project category meanings\n' >"$renamed_source/.basix/sources/categories.toml"
cp "$renamed_source/.basix/sources/sources.toml" "$case_dir/sources.before"
cp "$renamed_source/.basix/sources/categories.toml" "$case_dir/categories.before"
check 'project state records are relative to the project root' \
  state_targets_are_relative "$renamed_source/.codex/.basix-install-state"
renamed_target="$case_dir/rename-target"
mv "$renamed_source" "$renamed_target"
check 'project reinstall succeeds after directory rename' \
  "$ROOT/setup/install_for_project.sh" "$renamed_target" --no-local-network --no-test-socket
check 'renamed project keeps foreign root file' grep -Fxq 'keep me' "$renamed_target/foreign.keep"
check 'renamed project keeps foreign config sibling' grep -Fxq 'foreign config sibling' "$renamed_target/.codex/foreign.toml"
check 'renamed project state remains relative' \
  state_targets_are_relative "$renamed_target/.codex/.basix-install-state"
check 'project reinstall preserves source knowledge bytes' cmp -s "$case_dir/sources.before" "$renamed_target/.basix/sources/sources.toml"
check 'project reinstall preserves category meanings bytes' cmp -s "$case_dir/categories.before" "$renamed_target/.basix/sources/categories.toml"
check 'renamed project uninstall succeeds' \
  "$ROOT/setup/install_for_project.sh" "$renamed_target" --uninstall
check 'renamed project uninstall preserves foreign files' \
  foreign_files_are_preserved \
  "$renamed_target/foreign.keep" "$renamed_target/.codex/foreign.toml"
check 'renamed project uninstall removes managed payloads' test ! -e "$renamed_target/.agents/skills/basix" -a ! -e "$renamed_target/.codex/basix"
check 'renamed project uninstall removes install state' test ! -e "$renamed_target/.codex/.basix-install-state"
check 'project uninstall preserves source knowledge bytes' cmp -s "$case_dir/sources.before" "$renamed_target/.basix/sources/sources.toml"
check 'project uninstall preserves category meanings bytes' cmp -s "$case_dir/categories.before" "$renamed_target/.basix/sources/categories.toml"

legacy_source="$case_dir/legacy-source"
"$ROOT/setup/install_for_project.sh" "$legacy_source" --no-local-network --no-test-socket >/dev/null
legacy_target="$case_dir/legacy-target"
mv "$legacy_source" "$legacy_target"
awk -F '\t' -v OFS='\t' -v old="$legacy_source" '{if ($2 !~ /^\//) $2=old "/" $2; print}' \
  "$legacy_target/.codex/.basix-install-state" >"$case_dir/legacy-state"
mv "$case_dir/legacy-state" "$legacy_target/.codex/.basix-install-state"
check 'legacy absolute state rebases after project move' \
  "$ROOT/setup/install_for_project.sh" "$legacy_target" --no-local-network --no-test-socket
check 'legacy absolute state is rewritten relatively' \
  state_targets_are_relative "$legacy_target/.codex/.basix-install-state"

recreate="$case_dir/recreate-config"
"$ROOT/setup/install_for_project.sh" "$recreate" --local-network --test-socket >/dev/null
cp "$recreate/.codex/config.toml" "$case_dir/recreate-config.initial"
printf 'foreign config sibling\n' >"$recreate/.codex/foreign.toml"
rm -- "$recreate/.codex/config.toml"
check 'reinstall recreates deleted project config' \
  "$ROOT/setup/install_for_project.sh" "$recreate" --local-network --test-socket
check 'recreated config preserves managed behavior' cmp -s "$case_dir/recreate-config.initial" "$recreate/.codex/config.toml"
check 'reinstall preserves foreign config sibling' grep -Fxq 'foreign config sibling' "$recreate/.codex/foreign.toml"
check 'reinstall retains install state after config recreation' test -s "$recreate/.codex/.basix-install-state"

source_copy="$case_dir/source"; cp -R "$ROOT" "$source_copy"; update="$case_dir/update"
legacy_source="$source_copy/skills/basix/references/agent-communication-contract.md"
legacy_target="$update/.agents/skills/basix/references/agent-communication-contract.md"
cp "$source_copy/skills/basix-subagent-management/references/agent-communication-contract.md" "$legacy_source"
"$source_copy/setup/install_for_project.sh" "$update" --no-local-network --no-test-socket >/dev/null
rm -- "$legacy_source"
printf '\ncopy-update\n' >>"$source_copy/skills/basix/SKILL.md"
printf '\n# report-update\n' >>"$source_copy/agents/native/basix-pager.toml"
update_output=$("$source_copy/setup/install_for_project.sh" "$update" --no-local-network --no-test-socket)
check 'project reinstall reports changed agent as updated' grep -Fq 'basix-pager.toml — updated' <<<"$update_output"
check 'migration removes old router-owned contract path' test ! -e "$legacy_target"
check 'migration preserves management contract' cmp -s "$source_copy/skills/basix-subagent-management/references/agent-communication-contract.md" "$update/.agents/skills/basix-subagent-management/references/agent-communication-contract.md"
check 'reinstall synchronizes source updates' grep -Fq copy-update "$update/.agents/skills/basix/SKILL.md"
for agent in "$source_copy"/agents/native/*.toml; do
  check "project reinstall preserves $(basename "$agent") bytes" cmp -s "$agent" "$update/.codex/basix/agents/$(basename "$agent")"
done
stale_source="$source_copy/skills/basix-subagent-management/references/agent-communication-contract.md"
stale_target="$update/.agents/skills/basix-subagent-management/references/agent-communication-contract.md"
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
for skill in basix-subagent-management basix-planning basix-adr basix-agent-memory basix-source-memory; do
  check "project uninstall removes managed $skill tree" test ! -e "$clean/.agents/skills/$skill"
done

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

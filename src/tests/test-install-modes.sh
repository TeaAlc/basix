#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/setup/lib/common.sh"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
passes=0 failures=0
ok() { printf 'ok - %s\n' "$1"; ((passes+=1)); }
bad() { printf 'not ok - %s\n' "$1"; ((failures+=1)); }
expect() { local label=$1; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }

mock="$case_dir/bin"
mkdir -p "$mock"
cat >"$mock/codex" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'plugin marketplace list'*) printf '[]\n' ;;
  *'plugin list'*) printf '[]\n' ;;
  *'mcp get lumen'*) exit 1 ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$mock/codex"
export PATH="$mock:$PATH"

project_install() {
  "$ROOT/setup/install_for_project.sh" "$1" "${@:2}" --install-lumen no --lumen-index no >/dev/null
}
global_install() {
  local home=$1; shift
  CODEX_HOME="$home" "$ROOT/setup/install_as_plugin.sh" "$@" --install-lumen no >/dev/null
}
agent_config_valid() {
  python3 - "$1" "$2" <<'PY'
import os, sys, tomllib
config, prefix = sys.argv[1:]
value = tomllib.load(open(config, 'rb'))
expected = {'basix_file_explorer', 'basix_pager', 'basix_researcher', 'basix_verifier'}
assert expected <= set(value['agents'])
for name in expected:
    path = value['agents'][name]['config_file']
    assert path.startswith(prefix + os.sep), (path, prefix)
    assert os.path.isfile(path), path
PY
}

link_project="$case_dir/project-link"
project_install "$link_project" --mode link
if [[ -L $link_project/.agents/skills/basix &&
      $(readlink "$link_project/.agents/skills/basix") == "$ROOT/skills/basix" &&
      ! -L $link_project/.agents/skills/basix/SKILL.md &&
      -L $link_project/.codex/basix/agents &&
      $(readlink "$link_project/.codex/basix/agents") == "$ROOT/agents/native" &&
      ! -e $link_project/.codex/agents/basix-researcher.toml ]] &&
   agent_config_valid "$link_project/.codex/config.toml" "$link_project/.codex/basix/agents"; then
  ok 'fresh project link uses directory links and private registered agents'
else bad 'fresh project link uses directory links and private registered agents'; fi

before=$(sha256sum "$link_project/.codex/config.toml" "$link_project/.codex/.basix-install-state")
project_install "$link_project" --mode link
after=$(sha256sum "$link_project/.codex/config.toml" "$link_project/.codex/.basix-install-state")
expect 'project link reinstall is idempotent' test "$before" = "$after"

copy_project="$case_dir/project-copy"
project_install "$copy_project" --mode copy
if [[ -d $copy_project/.agents/skills/basix && ! -L $copy_project/.agents/skills/basix &&
      -d $copy_project/.codex/basix/agents && ! -L $copy_project/.codex/basix/agents ]] &&
   ! find "$copy_project/.agents/skills" "$copy_project/.codex/basix" -type l -print -quit | grep -q . &&
   agent_config_valid "$copy_project/.codex/config.toml" "$copy_project/.codex/basix/agents"; then
  ok 'fresh project copy contains complete trees without symlinks'
else bad 'fresh project copy contains complete trees without symlinks'; fi

project_install "$link_project" --mode copy
expect 'link to copy replaces managed directory links' test ! -L "$link_project/.agents/skills/basix" -a ! -L "$link_project/.codex/basix/agents"
project_install "$link_project" --mode link
expect 'copy to link restores canonical directory links' test "$(readlink "$link_project/.agents/skills/basix")" = "$ROOT/skills/basix"

legacy="$case_dir/legacy"
mkdir -p "$legacy/.agents/skills/basix" "$legacy/.codex/agents"
ln -s "$ROOT/skills/basix/SKILL.md" "$legacy/.agents/skills/basix/SKILL.md"
ln -s "$ROOT/agents/native/basix-researcher.toml" "$legacy/.codex/agents/basix-researcher.toml"
printf 'link\t%s\t%s\n' "$legacy/.agents/skills/basix/SKILL.md" "$ROOT/skills/basix/SKILL.md" >"$legacy/.codex/.basix-install-state"
printf 'link\t%s\t%s\n' "$legacy/.codex/agents/basix-researcher.toml" "$ROOT/agents/native/basix-researcher.toml" >>"$legacy/.codex/.basix-install-state"
project_install "$legacy" --mode link
if [[ -L $legacy/.agents/skills/basix && ! -L $legacy/.agents/skills/basix/SKILL.md &&
      ! -e $legacy/.codex/agents/basix-researcher.toml && -L $legacy/.codex/basix/agents ]]; then
  ok 'legacy file links migrate to directory links and private agents'
else bad 'legacy file links migrate to directory links and private agents'; fi

redirected="$case_dir/redirected"
project_install "$redirected" --mode link
unlink "$redirected/.agents/skills/basix"
ln -s "$ROOT/skills/basix-agent-authoring" "$redirected/.agents/skills/basix"
project_install "$redirected" --mode link
expect 'reinstall converges redirected managed directory link' test "$(readlink "$redirected/.agents/skills/basix")" = "$ROOT/skills/basix"
unlink "$redirected/.agents/skills/basix"
ln -s "$redirected/.agents/skills/basix" "$redirected/.agents/skills/basix"
project_install "$redirected" --mode link
expect 'reinstall converges cyclic managed directory link' test "$(readlink "$redirected/.agents/skills/basix")" = "$ROOT/skills/basix"

foreign="$case_dir/foreign-skill"
mkdir -p "$foreign/.agents/skills/basix"
printf 'foreign\n' >"$foreign/.agents/skills/basix/foreign.txt"
if project_install "$foreign" --mode link 2>"$case_dir/foreign.err"; then
  bad 'foreign skill content aborts before mutation'
elif [[ -f $foreign/.agents/skills/basix/foreign.txt && ! -e $foreign/.codex/config.toml && ! -e $foreign/.agents/skills/basix-agent-authoring ]]; then
  ok 'foreign skill content aborts before mutation'
else bad 'foreign skill content aborts before mutation'; fi

conflict="$case_dir/conflict"
mkdir -p "$conflict/.codex"
printf '[agents.basix_researcher]\nconfig_file = "/foreign.toml"\n' >"$conflict/.codex/config.toml"
conflict_before=$(sha256sum "$conflict/.codex/config.toml")
if project_install "$conflict" --mode link 2>"$case_dir/conflict.err"; then
  bad 'same-name foreign agent config aborts before mutation'
elif [[ $(sha256sum "$conflict/.codex/config.toml") == "$conflict_before" && ! -e $conflict/.agents ]]; then
  ok 'same-name foreign agent config aborts before mutation'
else bad 'same-name foreign agent config aborts before mutation'; fi
expect 'agent conflict explains the conflicting name' grep -q 'basix_researcher' "$case_dir/conflict.err"

coexist="$case_dir/coexist"
mkdir -p "$coexist/.codex/agents"
printf 'name = "foreign"\n' >"$coexist/.codex/agents/foreign.toml"
project_install "$coexist" --mode link
if [[ -f $coexist/.codex/agents/foreign.toml && ! -e $coexist/.codex/agents/basix-pager.toml ]]; then
  ok 'foreign shared agent coexists and no Basix agent is written there'
else bad 'foreign shared agent coexists and no Basix agent is written there'; fi

stateless="$case_dir/stateless"
project_install "$stateless" --mode link
rm "$stateless/.codex/.basix-install-state"
project_install "$stateless" --mode link
expect 'state-less canonical directory links are adopted' grep -q $'^dirlink\t' "$stateless/.codex/.basix-install-state"

dry="$case_dir/dry"
project_install "$dry" --mode link --dry-run
expect 'dry-run performs validation without target mutation' test ! -e "$dry"

linked_parent="$case_dir/linked-parent"
mkdir -p "$linked_parent/.agents"
ln -s "$ROOT/skills" "$linked_parent/.agents/skills"
source_before=$(find "$ROOT/skills/basix" -type f -exec sha256sum {} + | sort | sha256sum)
if project_install "$linked_parent" --mode link 2>"$case_dir/linked-parent.err"; then
  bad 'directory install rejects a parent alias to canonical sources'
elif [[ $(find "$ROOT/skills/basix" -type f -exec sha256sum {} + | sort | sha256sum) == "$source_before" &&
        -L $linked_parent/.agents/skills ]]; then
  ok 'directory install rejects a parent alias to canonical sources'
else bad 'directory install rejects a parent alias to canonical sources'; fi

linked_config="$case_dir/linked-config"
linked_config_external="$case_dir/linked-config-external"
mkdir -p "$linked_config" "$linked_config_external"
printf 'sentinel\n' >"$linked_config_external/sentinel"
ln -s "$linked_config_external" "$linked_config/.codex"
if project_install "$linked_config" --mode copy 2>"$case_dir/linked-config.err"; then
  bad 'installer rejects a linked configuration parent'
elif [[ -f $linked_config_external/sentinel && ! -e $linked_config_external/config.toml && ! -e $linked_config_external/.basix-install-state ]]; then
  ok 'installer rejects a linked configuration parent'
else bad 'installer rejects a linked configuration parent'; fi

linked_uninstall="$case_dir/linked-uninstall"
linked_uninstall_external="$case_dir/linked-uninstall-external"
project_install "$linked_uninstall" --mode copy
mv "$linked_uninstall/.agents" "$linked_uninstall_external"
ln -s "$linked_uninstall_external" "$linked_uninstall/.agents"
linked_uninstall_before=$(find "$linked_uninstall_external" -type f -exec sha256sum {} + | sort | sha256sum)
project_install "$linked_uninstall" --uninstall
linked_uninstall_after=$(find "$linked_uninstall_external" -type f -exec sha256sum {} + | sort | sha256sum)
if [[ $linked_uninstall_before == "$linked_uninstall_after" && -L $linked_uninstall/.agents ]]; then
  ok 'uninstall never follows a newly linked payload parent'
else bad 'uninstall never follows a newly linked payload parent'; fi

special_target="$case_dir/special-target"
mkdir -p "$special_target/.agents/skills"
cp -a "$ROOT/skills/basix" "$special_target/.agents/skills/basix"
rm "$special_target/.agents/skills/basix/SKILL.md"
mkfifo "$special_target/.agents/skills/basix/SKILL.md"
if project_install "$special_target" --mode link 2>"$case_dir/special-target.err"; then
  bad 'installer preserves and rejects a foreign special target node'
elif [[ -p $special_target/.agents/skills/basix/SKILL.md ]]; then
  ok 'installer preserves and rejects a foreign special target node'
else bad 'installer preserves and rejects a foreign special target node'; fi

special_source="$case_dir/special-source"
cp -a "$ROOT" "$special_source"
mkfifo "$special_source/skills/basix/source.fifo"
if "$special_source/setup/install_for_project.sh" "$case_dir/special-source-target" --mode copy --install-lumen no --lumen-index no >/dev/null 2>&1; then
  bad 'installer rejects special nodes in Basix source trees'
elif [[ ! -e $case_dir/special-source-target/.agents ]]; then
  ok 'installer rejects special nodes in Basix source trees'
else bad 'installer rejects special nodes in Basix source trees'; fi

preserve="$case_dir/preserve"
project_install "$preserve" --mode copy
printf '\nlocal\n' >>"$preserve/.agents/skills/basix/SKILL.md"
mkdir -p "$preserve/.agents/skills/basix/foreign-dir" "$preserve/.codex/foreign-dir"
printf 'foreign\n' >"$preserve/.agents/skills/basix/foreign-dir/keep.txt"
printf 'foreign codex\n' >"$preserve/.codex/foreign-dir/keep.txt"
ln -s "$case_dir" "$preserve/.agents/skills/basix/foreign-link"
project_install "$preserve" --uninstall
if grep -q local "$preserve/.agents/skills/basix/SKILL.md" &&
   [[ -f $preserve/.agents/skills/basix/foreign-dir/keep.txt && -L $preserve/.agents/skills/basix/foreign-link &&
      -f $preserve/.codex/foreign-dir/keep.txt && ! -e $preserve/.codex/basix/agents &&
      ! -e $preserve/.agents/skills/basix/agents/openai.yaml && -f $preserve/.codex/.basix-install-state ]]; then
  ok 'copy uninstall removes unchanged inventory and preserves changed, foreign, and linked content'
else bad 'copy uninstall removes unchanged inventory and preserves changed, foreign, and linked content'; fi

expect 'copy state records per-file install hashes' grep -q $'^dirfile\t' "$copy_project/.codex/.basix-install-state"

config_owner="$case_dir/config-owner"
mkdir -p "$config_owner/.codex"
printf '# before\nmodel = "foreign"\ndeveloper_instructions = "before\\n\\nafter"\n\n[foreign]\nvalue = 7 # keep\n' >"$config_owner/.codex/config.toml"
cp "$config_owner/.codex/config.toml" "$case_dir/config-owner.original"
project_install "$config_owner" --mode copy
project_install "$config_owner" --uninstall
if cmp -s "$case_dir/config-owner.original" "$config_owner/.codex/config.toml"; then
  ok 'uninstall preserves foreign config keys, comments, and instruction bytes exactly'
else bad 'uninstall preserves foreign config keys, comments, and instruction bytes exactly'; fi

mixed_agents="$case_dir/mixed-agents"
project_install "$mixed_agents" --mode copy
sed -i '/# basix:agent-config:end/i # foreign-in-marker\n[agents.foreign_inside]\nconfig_file = "/foreign.toml"\n' "$mixed_agents/.codex/config.toml"
project_install "$mixed_agents" --uninstall
if grep -q '^# foreign-in-marker$' "$mixed_agents/.codex/config.toml" &&
   grep -q '^\[agents.foreign_inside\]$' "$mixed_agents/.codex/config.toml" &&
   ! grep -q 'basix:agent-config\|\[agents.basix_' "$mixed_agents/.codex/config.toml"; then
  ok 'agent uninstall removes managed tables while preserving foreign tables inside markers'
else bad 'agent uninstall removes managed tables while preserving foreign tables inside markers'; fi

legacy_copy="$case_dir/legacy-copy"
mkdir -p "$legacy_copy/.agents/skills"
cp -a "$ROOT/skills/basix" "$legacy_copy/.agents/skills/basix"
printf 'foreign\n' >"$legacy_copy/.agents/skills/basix/foreign.txt"
mkdir -p "$legacy_copy/.codex"
legacy_hash=$(awk -F '\t' -v target="$copy_project/.agents/skills/basix" '$1 == "dircopy" && $2 == target { print $3; exit }' "$copy_project/.codex/.basix-install-state")
printf 'dircopy\t%s\t%s\n' "$legacy_copy/.agents/skills/basix" "$legacy_hash" >"$legacy_copy/.codex/.basix-install-state"
project_install "$legacy_copy" --uninstall
if [[ -f $legacy_copy/.agents/skills/basix/foreign.txt && ! -e $legacy_copy/.agents/skills/basix/SKILL.md ]]; then
  ok 'legacy dircopy state selectively removes current unchanged Basix files'
else bad 'legacy dircopy state selectively removes current unchanged Basix files'; fi

legacy_exact="$case_dir/legacy-exact"
mkdir -p "$legacy_exact/.agents/skills" "$legacy_exact/.codex"
cp -a "$ROOT/skills/basix" "$legacy_exact/.agents/skills/obsolete-basix"
printf 'dircopy\t%s\t%s\n' "$legacy_exact/.agents/skills/obsolete-basix" "$legacy_hash" >"$legacy_exact/.codex/.basix-install-state"
project_install "$legacy_exact" --uninstall
expect 'legacy source-absent exact dircopy state removes its regular tree' test ! -e "$legacy_exact/.agents/skills/obsolete-basix"

redirected_uninstall="$case_dir/redirected-uninstall"
project_install "$redirected_uninstall" --mode link
unlink "$redirected_uninstall/.agents/skills/basix"
ln -s "$ROOT/skills/basix-agent-authoring" "$redirected_uninstall/.agents/skills/basix"
project_install "$redirected_uninstall" --uninstall
expect 'uninstall preserves redirected managed directory links' test -L "$redirected_uninstall/.agents/skills/basix"

stateless_uninstall="$case_dir/stateless-uninstall"
project_install "$stateless_uninstall" --mode link
rm "$stateless_uninstall/.codex/.basix-install-state"
project_install "$stateless_uninstall" --uninstall
expect 'state-less uninstall preserves unowned payload links' test -L "$stateless_uninstall/.agents/skills/basix"

dry_uninstall="$case_dir/dry-uninstall"
project_install "$dry_uninstall" --mode copy
dry_before=$(find "$dry_uninstall" -type f -exec sha256sum {} + | sort | sha256sum)
project_install "$dry_uninstall" --uninstall --dry-run
dry_after=$(find "$dry_uninstall" -type f -exec sha256sum {} + | sort | sha256sum)
expect 'uninstall dry-run applies ownership checks without mutation' test "$dry_before" = "$dry_after"

clean_uninstall="$case_dir/clean-uninstall"
project_install "$clean_uninstall" --mode link
project_install "$clean_uninstall" --uninstall
if [[ ! -e $clean_uninstall/.agents/skills/basix && ! -e $clean_uninstall/.codex/basix/agents ]] &&
   ! grep -q 'basix:agent-config:start' "$clean_uninstall/.codex/config.toml" 2>/dev/null; then
  ok 'uninstall removes exact managed directory links and agent block'
else bad 'uninstall removes exact managed directory links and agent block'; fi

bundle="$case_dir/bundle"
cp -a "$ROOT" "$bundle"
mkdir -p "$bundle/skills/temporary"
printf '%s\n' '---' 'name: temporary' 'description: Temporary test skill.' '---' >"$bundle/skills/temporary/SKILL.md"
dynamic="$case_dir/dynamic"
"$bundle/setup/install_for_project.sh" "$dynamic" --mode copy --install-lumen no --lumen-index no >/dev/null
rm -rf "$bundle/skills/temporary"
"$bundle/setup/install_for_project.sh" "$dynamic" --mode copy --install-lumen no --lumen-index no >/dev/null
expect 'reinstall removes a skill removed from the source manifest' test ! -e "$dynamic/.agents/skills/temporary"

stale_mixed="$case_dir/stale-mixed"
stale_mixed_target="$stale_mixed/.agents/skills/removed"
mkdir -p "$stale_mixed_target" "$stale_mixed/.codex/agents"
printf 'original\n' >"$stale_mixed_target/SKILL.md"
printf 'managed\n' >"$stale_mixed_target/managed.txt"
printf 'dircopy\t%s\tunused\n' "$stale_mixed_target" >"$stale_mixed/old-state"
printf 'dirfile\t%s\tSKILL.md\t%s\n' "$stale_mixed_target" "$(sha256_file "$stale_mixed_target/SKILL.md")" >>"$stale_mixed/old-state"
printf 'dirfile\t%s\tmanaged.txt\t%s\n' "$stale_mixed_target" "$(sha256_file "$stale_mixed_target/managed.txt")" >>"$stale_mixed/old-state"
: >"$stale_mixed/new-state"
printf '\nlocal\n' >>"$stale_mixed_target/SKILL.md"
printf 'foreign\n' >"$stale_mixed_target/foreign.txt"
# Globals are consumed by functions sourced from common.sh.
# shellcheck disable=SC2034
DRY_RUN=false INSTALL_TARGET_ROOT=$stale_mixed STALE_CHANGED=false
reconcile_stale_targets "$stale_mixed/old-state" "$stale_mixed/new-state" "$stale_mixed/.codex/agents" "$stale_mixed/.agents/skills"
if grep -q local "$stale_mixed_target/SKILL.md" &&
   [[ -f $stale_mixed_target/foreign.txt && ! -e $stale_mixed_target/managed.txt ]]; then
  ok 'stale copy reconciliation removes only unchanged inventory files'
else bad 'stale copy reconciliation removes only unchanged inventory files'; fi

stale_link="$case_dir/stale-link"
stale_link_target="$stale_link/.agents/skills/removed"
mkdir -p "$stale_link/.agents/skills" "$stale_link/.codex/agents" "$case_dir/stale-link-foreign"
ln -s "$case_dir/stale-link-foreign" "$stale_link_target"
printf 'dirlink\t%s\t%s\n' "$stale_link_target" "$case_dir/removed-source" >"$stale_link/old-state"
: >"$stale_link/new-state"
# Globals are consumed by functions sourced from common.sh.
# shellcheck disable=SC2034
DRY_RUN=false INSTALL_TARGET_ROOT=$stale_link STALE_CHANGED=false
reconcile_stale_targets "$stale_link/old-state" "$stale_link/new-state" "$stale_link/.codex/agents" "$stale_link/.agents/skills"
expect 'stale reconciliation preserves redirected directory links' test "$(readlink "$stale_link_target")" = "$case_dir/stale-link-foreign"

root_state="$case_dir/root-target-state"
project_managed_root="$case_dir/root-target-project/.agents/skills"
global_managed_root="$case_dir/root-target-global/basix-plugin-root"
mkdir -p "$project_managed_root" "$global_managed_root"
printf 'project foreign\n' >"$project_managed_root/foreign.txt"
printf 'global foreign\n' >"$global_managed_root/foreign.txt"
printf 'dircopy\t%s\t%s\n' "$project_managed_root" "$(sha256_tree "$project_managed_root")" >"$root_state"
printf 'dircopy\t%s\t%s\n' "$global_managed_root" "$(sha256_tree "$global_managed_root")" >>"$root_state"
# Globals are consumed by functions sourced from common.sh.
# shellcheck disable=SC2034
REMOVE_CHANGED=false REMOVE_PRESERVED=false REMOVE_PROCESSED_DIRECTORIES=''
remove_recorded_targets "$root_state" "$project_managed_root" "$global_managed_root"
if [[ -f $project_managed_root/foreign.txt && -f $global_managed_root/foreign.txt ]]; then
  ok 'manipulated state cannot remove an allowed ownership root'
else bad 'manipulated state cannot remove an allowed ownership root'; fi

mkdir -p "$bundle/skills/obsolete"
printf '%s\n' '---' 'name: obsolete' 'description: Obsolete test skill.' '---' >"$bundle/skills/obsolete/SKILL.md"
obsolete="$case_dir/obsolete"
"$bundle/setup/install_for_project.sh" "$obsolete" --mode copy --install-lumen no --lumen-index no >/dev/null
rm -rf "$bundle/skills/obsolete"
"$bundle/setup/install_for_project.sh" "$obsolete" --uninstall >/dev/null
expect 'uninstall removes unchanged inventoried trees absent from current source' test ! -e "$obsolete/.agents/skills/obsolete"

global_copy="$case_dir/global-copy"
global_install "$global_copy" --mode copy
if [[ -d $global_copy/basix-plugin-root/skills/basix && ! -L $global_copy/basix-plugin-root/skills/basix &&
      -d $global_copy/basix/agents && ! -L $global_copy/basix/agents ]] &&
   ! find "$global_copy/basix-plugin-root/skills" "$global_copy/basix" -type l -print -quit | grep -q .; then
  ok 'fresh global copy contains no payload symlinks'
else bad 'fresh global copy contains no payload symlinks'; fi

printf 'foreign plugin\n' >"$global_copy/basix-plugin-root/foreign.txt"
printf '\nlocal agent\n' >>"$global_copy/basix/agents/basix-researcher.toml"
global_install "$global_copy" --uninstall
if [[ -f $global_copy/basix-plugin-root/foreign.txt &&
      -f $global_copy/basix/agents/basix-researcher.toml &&
      ! -e $global_copy/basix/agents/basix-pager.toml &&
      ! -e $global_copy/basix-plugin-root/skills/basix/SKILL.md &&
      -f $global_copy/.basix-install-state ]]; then
  ok 'global copy uninstall preserves foreign plugin and changed agent content'
else bad 'global copy uninstall preserves foreign plugin and changed agent content'; fi

foreign_manifest="$case_dir/foreign-manifest"
foreign_manifest_dir="$case_dir/foreign-manifest-dir"
mkdir -p "$foreign_manifest/basix-plugin-root/.codex-plugin" "$foreign_manifest_dir"
printf 'foreign\n' >"$foreign_manifest_dir/sentinel"
ln -s "$foreign_manifest_dir" "$foreign_manifest/basix-plugin-root/.codex-plugin/plugin.json"
if global_install "$foreign_manifest" --mode copy 2>"$case_dir/foreign-manifest.err"; then
  bad 'global install rejects a foreign manifest directory link'
elif [[ -L $foreign_manifest/basix-plugin-root/.codex-plugin/plugin.json &&
        $(readlink "$foreign_manifest/basix-plugin-root/.codex-plugin/plugin.json") == "$foreign_manifest_dir" &&
        -f $foreign_manifest_dir/sentinel ]]; then
  ok 'global install rejects a foreign manifest directory link'
else bad 'global install rejects a foreign manifest directory link'; fi

printf '%d passed, %d failed\n' "$passes" "$failures"
((failures == 0))

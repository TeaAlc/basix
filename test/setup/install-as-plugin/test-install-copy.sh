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
source_copy="$case_dir/source"; cp -R "$ROOT" "$source_copy"

for option in --mode --force --install-lumen --lumen-index; do
  if CODEX_HOME="$case_dir/global-reject" "$ROOT/setup/install_as_plugin.sh" "$option" value >/dev/null 2>&1; then bad "global rejects $option"; else ok "global rejects $option"; fi
done

global="$case_dir/global"; first_output=$(CODEX_HOME="$global" "$ROOT/setup/install_as_plugin.sh")
if [[ -f $global/basix-plugin-root/skills/basix/SKILL.md && -f $global/basix-plugin-root/skills/basix-experience/scripts/collect-token-usage.py && -f $global/basix/agents/basix-researcher.toml ]] && ! find "$global/basix-plugin-root" "$global/basix" -type l -print -quit | grep -q .; then ok 'fresh global install uses copies only'; else bad 'fresh global install uses copies only'; fi
for agent in "$ROOT"/agents/native/*.toml; do
  check "global install reports $(basename "$agent") as installed" grep -Fq "$(basename "$agent") — installed" <<<"$first_output"
done
check 'global install preserves token collector bytes' cmp -s "$ROOT/skills/basix-experience/scripts/collect-token-usage.py" "$global/basix-plugin-root/skills/basix-experience/scripts/collect-token-usage.py"
for agent in "$ROOT"/agents/native/*.toml; do
  check "global install preserves $(basename "$agent") bytes" cmp -s "$agent" "$global/basix/agents/$(basename "$agent")"
done
second_output=$(CODEX_HOME="$global" "$ROOT/setup/install_as_plugin.sh")
for agent in "$ROOT"/agents/native/*.toml; do
  check "global reinstall reports $(basename "$agent") as unchanged" grep -Fq "$(basename "$agent") — unchanged" <<<"$second_output"
done
alias_home="$case_dir/global-alias"; mkdir -p "$alias_home/basix-plugin-root/.codex-plugin"; ln "$source_copy/plugin/plugin.json" "$alias_home/basix-plugin-root/.codex-plugin/plugin.json"
if CODEX_HOME="$alias_home" "$source_copy/setup/install_as_plugin.sh" >/dev/null 2>&1; then bad 'global alias is rejected before mutation'; elif [[ ! -e $alias_home/basix ]]; then ok 'global alias is rejected before mutation'; else bad 'global alias is rejected before mutation'; fi

printf '%d passed, %d failed\n' "$passes" "$failures"; ((failures == 0))

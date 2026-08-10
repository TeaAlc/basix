#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/src

bash -n "$ROOT/setup/install_ory_lumen.sh"

case_dir=$(mktemp -d); trap 'rm -rf "$case_dir"' EXIT
mock="$case_dir/bin"; home="$case_dir/home"; codex_home="$case_dir/codex"; mkdir -p "$mock" "$home"
cat >"$mock/codex" <<'SH'
#!/usr/bin/env bash
if [[ $1 == mcp && $2 == get ]]; then [[ -f $LUMEN_STATE ]] || exit 1; cat "$LUMEN_STATE"; exit; fi
if [[ $1 == mcp && $2 == add ]]; then
  printf '{"name":"lumen","enabled":true,"disabled_reason":null,"transport":{"command":"%s/lumen/scripts/run","args":["stdio"]}}\n' "$CODEX_HOME" >"$LUMEN_STATE"
  printf '%s\n' "$*" >>"$LUMEN_LOG"
  exit
fi
printf '%s\n' "$*" >>"$LUMEN_LOG"
SH
cat >"$mock/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LUMEN_LOG"
target=$3; mkdir -p "$target/scripts" "$target/skills"; printf '#!/usr/bin/env bash\n' >"$target/scripts/run"; chmod +x "$target/scripts/run"
SH
chmod +x "$mock/codex" "$mock/git"
log="$case_dir/lumen.log"; state="$case_dir/lumen.state"
PATH="$mock:$PATH" HOME="$home" CODEX_HOME="$codex_home" LUMEN_LOG="$log" LUMEN_STATE="$state" "$ROOT/setup/install_ory_lumen.sh" >/dev/null
[[ -L $home/.agents/skills/lumen && -f $state ]] || { printf 'not ok - standalone Lumen install\n'; exit 1; }
before=$(sha256sum "$log")
PATH="$mock:$PATH" HOME="$home" CODEX_HOME="$codex_home" LUMEN_LOG="$log" LUMEN_STATE="$state" "$ROOT/setup/install_ory_lumen.sh" >/dev/null
[[ $(sha256sum "$log") == "$before" ]] || { printf 'not ok - standalone Lumen reinstall\n'; exit 1; }
printf 'ok - standalone Lumen installer remains independent\n'

rm -rf "$codex_home/lumen" "$home/.agents/skills/lumen"
before=$(sha256sum "$log")
PATH="$mock:$PATH" HOME="$home" CODEX_HOME="$codex_home" LUMEN_LOG="$log" LUMEN_STATE="$state" "$ROOT/setup/install_ory_lumen.sh" >/dev/null
[[ -x $codex_home/lumen/scripts/run && -L $home/.agents/skills/lumen ]] || { printf 'not ok - Lumen runtime recovery\n'; exit 1; }
[[ $(grep -c '^mcp add ' "$log") == 1 && $(sha256sum "$log") != "$before" ]] || { printf 'not ok - Lumen recovery duplicated registration\n'; exit 1; }
printf 'ok - matching Lumen registration recovers missing runtime\n'

rm "$home/.agents/skills/lumen"
PATH="$mock:$PATH" HOME="$home" CODEX_HOME="$codex_home" LUMEN_LOG="$log" LUMEN_STATE="$state" "$ROOT/setup/install_ory_lumen.sh" >/dev/null
[[ -L $home/.agents/skills/lumen && $(readlink "$home/.agents/skills/lumen") == "$codex_home/lumen/skills" ]] || { printf 'not ok - missing Lumen skill link recovery\n'; exit 1; }
rm "$home/.agents/skills/lumen"; ln -s "$case_dir/wrong-skills" "$home/.agents/skills/lumen"
PATH="$mock:$PATH" HOME="$home" CODEX_HOME="$codex_home" LUMEN_LOG="$log" LUMEN_STATE="$state" "$ROOT/setup/install_ory_lumen.sh" --force >/dev/null
[[ $(readlink "$home/.agents/skills/lumen") == "$codex_home/lumen/skills" ]] || { printf 'not ok - wrong Lumen skill link recovery\n'; exit 1; }
[[ $(grep -c '^mcp add ' "$log") == 1 ]] || { printf 'not ok - Lumen skill recovery duplicated registration\n'; exit 1; }
printf 'ok - matching Lumen registration repairs skill links\n'

foreign_home="$case_dir/foreign-home"; foreign_codex="$case_dir/foreign-codex"; foreign_state="$case_dir/foreign.state"; foreign_log="$case_dir/foreign.log"
mkdir -p "$foreign_home/.agents/skills" "$foreign_codex"
printf '{"name":"lumen","enabled":true,"disabled_reason":null,"transport":{"command":"/foreign/lumen/run","args":["stdio"]}}\n' >"$foreign_state"
if PATH="$mock:$PATH" HOME="$foreign_home" CODEX_HOME="$foreign_codex" LUMEN_LOG="$foreign_log" LUMEN_STATE="$foreign_state" "$ROOT/setup/install_ory_lumen.sh" >/dev/null 2>&1; then
  printf 'not ok - foreign Lumen registration accepted\n'; exit 1
fi
[[ ! -e $foreign_codex/lumen && ! -e $foreign_home/.agents/skills/lumen && ! -e $foreign_log ]] || { printf 'not ok - foreign Lumen conflict mutated targets\n'; exit 1; }
printf 'ok - foreign Lumen registration is rejected without mutation\n'

helper="$ROOT/setup/lib/manage_developer_instructions.py"; config="$case_dir/config.toml"
python3 "$helper" add --config "$config" --instructions "$ROOT/setup/developer_instruction.md" >/dev/null
python3 "$helper" remove --config "$config" --remove-empty-file >/dev/null
[[ ! -e $config ]] || { printf 'not ok - developer instruction helper round trip\n'; exit 1; }
printf 'ok - developer instruction helper round trip\n'

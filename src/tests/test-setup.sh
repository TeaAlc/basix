#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

bash -n "$ROOT/setup/install_as_plugin.sh" "$ROOT/setup/install_for_project.sh" "$ROOT/setup/install_ory_lumen.sh" "$ROOT/setup/lib/common.sh"
"$ROOT/tests/test-install-copy.sh"

case_dir=$(mktemp -d); trap 'rm -rf "$case_dir"' EXIT
mock="$case_dir/bin"; home="$case_dir/home"; codex_home="$case_dir/codex"; mkdir -p "$mock" "$home"
cat >"$mock/codex" <<'SH'
#!/usr/bin/env bash
if [[ $1 == mcp && $2 == get ]]; then [[ -f $LUMEN_STATE ]] || exit 1; printf '{"name":"lumen","enabled":true}\n'; exit; fi
if [[ $1 == mcp && $2 == add ]]; then touch "$LUMEN_STATE"; printf '%s\n' "$*" >>"$LUMEN_LOG"; exit; fi
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

helper="$ROOT/setup/lib/manage_developer_instructions.py"; config="$case_dir/config.toml"
python3 "$helper" add --config "$config" --instructions "$ROOT/setup/developer_instruction.md" >/dev/null
python3 "$helper" remove --config "$config" --remove-empty-file >/dev/null
[[ ! -e $config ]] || { printf 'not ok - developer instruction helper round trip\n'; exit 1; }
printf 'ok - developer instruction helper round trip\n'

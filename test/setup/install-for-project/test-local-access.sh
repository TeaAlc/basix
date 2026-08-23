#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
src="$ROOT/src"
real_codex=$(command -v codex)
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
mock="$case_dir/bin"
mkdir -p "$mock"
printf '%s\n' '#!/usr/bin/env bash' 'printf "{}\\n"' >"$mock/codex"
chmod +x "$mock/codex"
export PATH="$mock:$PATH"

enabled="$case_dir/enabled"
output=$("$src/setup/install_for_project.sh" "$enabled" --local-network --test-socket 2>&1)
grep -Fq 'Project local access permissions' <<<"$output"
grep -Fq 'exactly the repository test socket' <<<"$output"
PYTHONDONTWRITEBYTECODE=1 python3 - "$enabled/.codex/config.toml" "$enabled" <<'PY'
import sys, tomllib
config = tomllib.loads(open(sys.argv[1], encoding="utf-8").read())
root = sys.argv[2]
profile = config["permissions"]["local-network-test-socket"]
assert config["default_permissions"] == "local-network-test-socket"
assert config["features"]["network_proxy"] is True
assert profile["network"]["domains"] == {
    "localhost": "allow", "127.0.0.1": "allow", "::1": "allow"
}
assert profile["network"]["unix_sockets"] == {root + "/test/test.sock": "allow"}
PY
parser_home="$case_dir/parser-home"
mkdir -p "$parser_home"
cp "$enabled/.codex/config.toml" "$parser_home/config.toml"
CODEX_HOME="$parser_home" "$real_codex" --strict-config --help >/dev/null 2>"$case_dir/parser.err"

before=$(sha256sum "$enabled/.codex/config.toml")
"$src/setup/install_for_project.sh" "$enabled" --local-network --test-socket >/dev/null 2>&1
test "$before" = "$(sha256sum "$enabled/.codex/config.toml")"

socket_only="$case_dir/socket-only"
"$src/setup/install_for_project.sh" "$socket_only" --no-local-network --test-socket >/dev/null 2>&1
PYTHONDONTWRITEBYTECODE=1 python3 - "$socket_only/.codex/config.toml" "$socket_only" <<'PY'
import sys, tomllib
config = tomllib.loads(open(sys.argv[1], encoding="utf-8").read())
root = sys.argv[2]
assert config["default_permissions"] == "test-socket"
assert "features" not in config
assert config["permissions"]["test-socket"]["network"]["unix_sockets"] == {
    root + "/test/test.sock": "allow"
}
PY
grep -Fq '<repopath>/test/test.sock' "$socket_only/.agents/skills/basix/SKILL.md"

legacy="$case_dir/legacy"
mkdir -p "$legacy/.codex"
PYTHONDONTWRITEBYTECODE=1 python3 - "$legacy/.codex/config.toml" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("helper", "src/setup/lib/manage_developer_instructions.py")
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
open(sys.argv[1], "w", encoding="utf-8").write(helper.playwright_add_text("")[0])
PY
"$src/setup/install_for_project.sh" "$legacy" --local-network --test-socket >/dev/null 2>&1
! grep -q 'permissions.playwright\|basix:playwright-' "$legacy/.codex/config.toml"
grep -Fq 'local-network-test-socket' "$legacy/.codex/config.toml"

"$src/setup/install_for_project.sh" "$enabled" --no-local-network --no-test-socket >/dev/null 2>&1
! grep -q 'basix:local-access-' "$enabled/.codex/config.toml"
grep -Fq 'developer_instructions' "$enabled/.codex/config.toml"

dry="$case_dir/dry"
"$src/setup/install_for_project.sh" "$dry" --local-network --test-socket --dry-run >/dev/null 2>&1
test ! -e "$dry"

missing="$case_dir/missing-choice"
if "$src/setup/install_for_project.sh" "$missing" >/dev/null 2>&1; then
  printf 'missing noninteractive choices unexpectedly succeeded\n' >&2
  exit 1
fi
test ! -e "$missing"

for old_flag in --playwright --no-playwright; do
  if "$src/setup/install_for_project.sh" "$case_dir/old-flag" "$old_flag" --test-socket >/dev/null 2>&1; then
    printf 'obsolete flag accepted: %s\n' "$old_flag" >&2
    exit 1
  fi
done
if "$src/setup/install_for_project.sh" "$case_dir/reject" --uninstall --test-socket >/dev/null 2>&1; then
  printf 'uninstall accepted a capability flag\n' >&2
  exit 1
fi

foreign="$case_dir/foreign"
mkdir -p "$foreign/.codex"
printf 'default_permissions = "workspace"\n' >"$foreign/.codex/config.toml"
if "$src/setup/install_for_project.sh" "$foreign" --local-network --test-socket >/dev/null 2>&1; then
  printf 'foreign local-access overlap unexpectedly succeeded\n' >&2
  exit 1
fi
test ! -e "$foreign/.agents"

foreign_disable="$case_dir/foreign-disable"
mkdir -p "$foreign_disable/.codex"
printf 'default_permissions = "workspace"\n' >"$foreign_disable/.codex/config.toml"
if "$src/setup/install_for_project.sh" "$foreign_disable" --no-local-network --no-test-socket >/dev/null 2>&1; then
  printf 'foreign disable overlap unexpectedly succeeded\n' >&2
  exit 1
fi
test ! -e "$foreign_disable/.agents"

broken_install="$case_dir/broken-install"
mkdir -p "$broken_install/.codex"
printf 'developer_instructions = "<!-- basix:developer-instructions:start -->"\n' >"$broken_install/.codex/config.toml"
if "$src/setup/install_for_project.sh" "$broken_install" --local-network --test-socket >/dev/null 2>&1; then
  printf 'malformed developer markers unexpectedly installed\n' >&2
  exit 1
fi
test ! -e "$broken_install/.agents"

broken_uninstall="$case_dir/broken-uninstall"
"$src/setup/install_for_project.sh" "$broken_uninstall" --local-network --test-socket >/dev/null 2>&1
sed -i 's/basix:developer-instructions:end/basix:developer-instructions:broken/' "$broken_uninstall/.codex/config.toml"
before_broken=$(sha256sum "$broken_uninstall/.codex/config.toml")
if "$src/setup/install_for_project.sh" "$broken_uninstall" --uninstall >/dev/null 2>&1; then
  printf 'malformed developer markers unexpectedly uninstalled\n' >&2
  exit 1
fi
test "$before_broken" = "$(sha256sum "$broken_uninstall/.codex/config.toml")"
test -e "$broken_uninstall/.agents/skills/basix/SKILL.md"
test -e "$broken_uninstall/.codex/.basix-install-state"
printf 'ok - local access project installer behavior\n'

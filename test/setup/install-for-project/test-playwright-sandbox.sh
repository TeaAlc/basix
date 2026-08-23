#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
src="$ROOT/src"
real_codex=$(command -v codex)
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
mock="$case_dir/bin"
mkdir -p "$mock"
cat >"$mock/codex" <<'SH'
#!/usr/bin/env bash
printf '{}\n'
SH
chmod +x "$mock/codex"
export PATH="$mock:$PATH"

enabled="$case_dir/enabled"
output=$("$src/setup/install_for_project.sh" "$enabled" --playwright 2>&1)
grep -Fq 'Playwright sandbox permissions — enable' <<<"$output"
grep -Fq 'newly started Codex sessions' <<<"$output"
PYTHONDONTWRITEBYTECODE=1 python3 - "$enabled/.codex/config.toml" <<'PY'
import sys, tomllib
config = tomllib.loads(open(sys.argv[1], encoding="utf-8").read())
assert config["default_permissions"] == "playwright"
assert config["features"]["network_proxy"] is True
profile = config["permissions"]["playwright"]
assert profile["extends"] == ":workspace"
assert profile["network"] == {
    "enabled": True,
    "mode": "limited",
    "allow_local_binding": True,
    "domains": {"localhost": "allow", "127.0.0.1": "allow", "::1": "allow"},
}
PY

parser_home="$case_dir/parser-home"
mkdir -p "$parser_home"
cp "$enabled/.codex/config.toml" "$parser_home/config.toml"
set +e
CODEX_HOME="$parser_home" "$real_codex" doctor --json >"$case_dir/doctor.json" 2>"$case_dir/doctor.err"
doctor_status=$?
set -e
test "$doctor_status" -ne 0
grep -Fq '"config.load"' "$case_dir/doctor.json"
grep -Fq '"status": "ok"' <(sed -n '/"config.load"/,/},/p' "$case_dir/doctor.json")

before=$(sha256sum "$enabled/.codex/config.toml")
"$src/setup/install_for_project.sh" "$enabled" --playwright >/dev/null 2>&1
test "$before" = "$(sha256sum "$enabled/.codex/config.toml")"

managed_no_dev="$case_dir/managed-no-dev"
mkdir -p "$managed_no_dev/.codex"
PYTHONDONTWRITEBYTECODE=1 python3 "$src/setup/lib/manage_developer_instructions.py" playwright-add --config "$managed_no_dev/.codex/config.toml" >/dev/null
"$src/setup/install_for_project.sh" "$managed_no_dev" --playwright >/dev/null 2>&1
PYTHONDONTWRITEBYTECODE=1 python3 - "$managed_no_dev/.codex/config.toml" <<'PY'
import sys, tomllib
config = tomllib.loads(open(sys.argv[1], encoding="utf-8").read())
assert isinstance(config["developer_instructions"], str)
assert config["permissions"]["playwright"]["network"]["domains"]["localhost"] == "allow"
assert "developer_instructions" not in config["permissions"]["playwright"]["network"]["domains"]
PY
test -e "$managed_no_dev/.codex/.basix-install-state"

"$src/setup/install_for_project.sh" "$enabled" --no-playwright >/dev/null 2>&1
! grep -q 'basix:playwright-' "$enabled/.codex/config.toml"
grep -Fq 'developer_instructions' "$enabled/.codex/config.toml"

dry="$case_dir/dry"
"$src/setup/install_for_project.sh" "$dry" --playwright --dry-run >/dev/null 2>&1
test ! -e "$dry"

missing="$case_dir/missing-choice"
if "$src/setup/install_for_project.sh" "$missing" >/dev/null 2>&1; then
  printf 'missing noninteractive choice unexpectedly succeeded\n' >&2
  exit 1
fi
test ! -e "$missing"

if "$src/setup/install_for_project.sh" "$case_dir/reject" --uninstall --playwright >/dev/null 2>&1; then
  printf 'uninstall accepted a Playwright flag\n' >&2
  exit 1
fi

foreign="$case_dir/foreign"
mkdir -p "$foreign/.codex"
printf 'default_permissions = "workspace"\n' >"$foreign/.codex/config.toml"
if "$src/setup/install_for_project.sh" "$foreign" --playwright >/dev/null 2>&1; then
  printf 'foreign Playwright overlap unexpectedly succeeded\n' >&2
  exit 1
fi
test ! -e "$foreign/.agents"

broken_install="$case_dir/broken-install"
mkdir -p "$broken_install/.codex"
printf 'developer_instructions = "<!-- basix:developer-instructions:start -->"\n' >"$broken_install/.codex/config.toml"
if "$src/setup/install_for_project.sh" "$broken_install" --playwright >/dev/null 2>&1; then
  printf 'malformed developer markers unexpectedly installed\n' >&2
  exit 1
fi
test ! -e "$broken_install/.agents"

broken_uninstall="$case_dir/broken-uninstall"
"$src/setup/install_for_project.sh" "$broken_uninstall" --playwright >/dev/null 2>&1
sed -i 's/basix:developer-instructions:end/basix:developer-instructions:broken/' "$broken_uninstall/.codex/config.toml"
before_broken=$(sha256sum "$broken_uninstall/.codex/config.toml")
if "$src/setup/install_for_project.sh" "$broken_uninstall" --uninstall >/dev/null 2>&1; then
  printf 'malformed developer markers unexpectedly uninstalled\n' >&2
  exit 1
fi
test "$before_broken" = "$(sha256sum "$broken_uninstall/.codex/config.toml")"
test -e "$broken_uninstall/.agents/skills/basix/SKILL.md"
test -e "$broken_uninstall/.codex/.basix-install-state"
printf 'ok - Playwright project installer behavior\n'

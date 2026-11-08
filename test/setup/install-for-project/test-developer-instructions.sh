#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/src
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
mkdir -p "$case_dir/bin"
printf '%s\n' '#!/usr/bin/env bash' 'printf "{}\n"' >"$case_dir/bin/codex"
chmod +x "$case_dir/bin/codex"
export PATH="$case_dir/bin:$PATH"
install_project() { "$ROOT/setup/install_for_project.sh" "$1" --no-local-network --no-test-socket >/dev/null; }

project="$case_dir/project"
mkdir -p "$project/.codex" "$project/.basix"
printf 'developer_instructions = "User rules"\n' >"$project/.codex/config.toml"
printf 'project knowledge\n' >"$project/.basix/foreign.keep"
install_project "$project"
cmp "$ROOT/setup/developer_instruction.md" "$project/.basix/developer_instructions.md"
python3 - "$project/.codex/config.toml" "$ROOT/setup/developer_instruction_reference.md" <<'PYTEST'
import sys, tomllib
from pathlib import Path
value = tomllib.loads(Path(sys.argv[1]).read_text())["developer_instructions"]
assert value.startswith("User rules\n\n")
assert Path(sys.argv[2]).read_text().strip() in value
assert "## Basix conventions" not in value
PYTEST
"$ROOT/setup/install_for_project.sh" "$project" --uninstall --dry-run >/dev/null
test -f "$project/.basix/developer_instructions.md"
rm "$project/.basix/developer_instructions.md"
install_project "$project"
cmp "$ROOT/setup/developer_instruction.md" "$project/.basix/developer_instructions.md"
printf '\nLocal rules\n' >>"$project/.basix/developer_instructions.md"
cp "$project/.basix/developer_instructions.md" "$case_dir/modified.before"
"$ROOT/setup/install_for_project.sh" "$project" --uninstall >/dev/null
cmp "$case_dir/modified.before" "$project/.basix/developer_instructions.md"
grep -Fxq 'project knowledge' "$project/.basix/foreign.keep"
grep -Fxq 'developer_instructions = "User rules"' "$project/.codex/config.toml"

for conflict in foreign-file linked-file linked-parent; do
  target="$case_dir/$conflict"
  mkdir -p "$target/.basix" "$case_dir/outside-$conflict"
  printf 'foreign instructions\n' >"$case_dir/outside-$conflict/developer_instructions.md"
  case $conflict in
    foreign-file) cp "$case_dir/outside-$conflict/developer_instructions.md" "$target/.basix/developer_instructions.md" ;;
    linked-file) ln -s "$case_dir/outside-$conflict/developer_instructions.md" "$target/.basix/developer_instructions.md" ;;
    linked-parent) rmdir "$target/.basix"; ln -s "$case_dir/outside-$conflict" "$target/.basix" ;;
  esac
  if install_project "$target" 2>/dev/null; then
    printf 'unsafe instruction target accepted: %s\n' "$conflict" >&2; exit 1
  fi
  test ! -e "$target/.agents"
  test ! -e "$target/.codex"
  grep -Fxq 'foreign instructions' "$case_dir/outside-$conflict/developer_instructions.md"
done

linked="$case_dir/uninstall-parent"
install_project "$linked"
mv "$linked/.basix" "$case_dir/relocated-basix"
ln -s "$case_dir/relocated-basix" "$linked/.basix"
"$ROOT/setup/install_for_project.sh" "$linked" --uninstall >/dev/null
test -f "$case_dir/relocated-basix/developer_instructions.md"
printf 'ok - project developer instruction ownership and safety\n'

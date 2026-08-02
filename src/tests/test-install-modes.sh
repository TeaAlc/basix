#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
passes=0 failures=0
ok() { printf 'ok - %s\n' "$1"; passes=$((passes + 1)); }
bad() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }
expect() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

mkdir -p "$case_dir/bin"
cat >"$case_dir/bin/codex" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$case_dir/bin/codex"
export PATH="$case_dir/bin:$PATH"

run_tty_default() {
  python3 - "$@" <<'PY'
import os, pty, subprocess, sys
master, slave = pty.openpty()
p = subprocess.Popen(sys.argv[1:], stdin=slave, stdout=slave, stderr=slave)
os.close(slave)
os.write(master, b"\n")
while True:
    try:
        if not os.read(master, 4096):
            break
    except OSError:
        break
os.close(master)
raise SystemExit(p.wait())
PY
}

interactive="$case_dir/interactive"
run_tty_default "$ROOT/setup/install_for_project.sh" "$interactive" --install-lumen no --lumen-index no
expect 'interactive ordinary default is link' test -L "$interactive/.agents/skills/basix/SKILL.md"
expect 'interactive install does not create .basix' test ! -e "$interactive/.basix"

ordinary="$case_dir/ordinary"
"$ROOT/setup/install_for_project.sh" "$ordinary" --install-lumen no --lumen-index no >/dev/null 2>&1
expect 'non-TTY ordinary default is link' test -L "$ordinary/.agents/skills/basix/SKILL.md"
expect 'non-TTY install does not create .basix' test ! -e "$ordinary/.basix"
expect 'link targets canonical agent source directly' test "$(readlink "$ordinary/.codex/agents/basix-researcher.toml")" = "$ROOT/agents/native/basix-researcher.toml"
expect 'link mode discovers canonical pager agent' test "$(readlink "$ordinary/.codex/agents/basix-pager.toml")" = "$ROOT/agents/native/basix-pager.toml"
expect 'link mode discovers canonical verifier agent' test "$(readlink "$ordinary/.codex/agents/basix-verifier.toml")" = "$ROOT/agents/native/basix-verifier.toml"
expect 'link targets canonical skill source directly' test "$(readlink "$ordinary/.agents/skills/basix/SKILL.md")" = "$ROOT/skills/basix/SKILL.md"

owned="$case_dir/project-owned-basix"; mkdir -p "$owned/.basix"
printf 'memory\n' > "$owned/.basix/memory.md"; printf 'credentials\n' > "$owned/.basix/credentials.md"; printf 'foreign\n' > "$owned/.basix/custom.dat"
owned_before=$(sha256sum "$owned/.basix/memory.md" "$owned/.basix/credentials.md" "$owned/.basix/custom.dat")
"$ROOT/setup/install_for_project.sh" "$owned" --mode link --install-lumen no --lumen-index no >/dev/null 2>&1
"$ROOT/setup/install_for_project.sh" "$owned" --mode copy --force --install-lumen no --lumen-index no >/dev/null 2>&1
"$ROOT/setup/install_for_project.sh" "$owned" --mode link --dry-run --force --install-lumen no --lumen-index no >/dev/null 2>&1
"$ROOT/setup/install_for_project.sh" "$owned" --uninstall >/dev/null 2>&1
owned_after=$(sha256sum "$owned/.basix/memory.md" "$owned/.basix/credentials.md" "$owned/.basix/custom.dat")
expect 'install, update, force, dry-run, and uninstall preserve project-owned .basix byte-for-byte' test "$owned_before" = "$owned_after"

"$ROOT/setup/install_for_project.sh" "$ordinary" --mode copy --install-lumen no --lumen-index no >/dev/null 2>&1
expect 'explicit copy does not create a bundle' test ! -e "$ordinary/.basix"
expect 'link-to-copy migration installs agent copies' test ! -L "$ordinary/.codex/agents/basix-researcher.toml" -a ! -L "$ordinary/.codex/agents/basix-pager.toml" -a ! -L "$ordinary/.codex/agents/basix-verifier.toml" -a -f "$ordinary/.codex/agents/basix-pager.toml" -a -f "$ordinary/.codex/agents/basix-verifier.toml"
expect 'copy includes complete nested skill tree' test ! -L "$ordinary/.agents/skills/basix-agent-authoring/references/message.schema.json"
"$ROOT/setup/install_for_project.sh" "$ordinary" --mode link --install-lumen no --lumen-index no >/dev/null 2>&1
expect 'copy-to-link migration is safe without force' test -L "$ordinary/.codex/agents/basix-researcher.toml" -a -L "$ordinary/.codex/agents/basix-pager.toml" -a -L "$ordinary/.codex/agents/basix-verifier.toml"

self="$case_dir/self"; mkdir -p "$self"; cp -R "$ROOT" "$self/src"
mkdir -p "$self/.codex" "$self/.agents/skills"
ln -s "$self/src/agents/native" "$self/.codex/agents"
for skill in "$self"/src/skills/*; do ln -s "$skill" "$self/.agents/skills/${skill##*/}"; done
"$self/src/setup/install_for_project.sh" "$self" --install-lumen no --lumen-index no >/dev/null 2>&1
if [[ -d $self/.codex/agents && ! -L $self/.codex/agents && ! -L $self/.codex/agents/basix-researcher.toml && ! -L $self/.codex/agents/basix-pager.toml && ! -L $self/.codex/agents/basix-verifier.toml ]]; then ok 'non-TTY self-host default is copy'; else bad 'non-TTY self-host default is copy'; fi
expect 'self-host does not create .basix' test ! -e "$self/.basix"
"$self/src/setup/install_for_project.sh" "$self" --mode link --install-lumen no --lumen-index no >/dev/null 2>&1
expect 'switch back restores exact agent directory link' test "$(readlink "$self/.codex/agents")" = "$self/src/agents/native"
expect 'switch back restores exact skill directory link' test "$(readlink "$self/.agents/skills/basix")" = "$self/src/skills/basix"

renamed="$case_dir/checkout-with-another-name"; mkdir -p "$renamed"; cp -R "$ROOT" "$renamed/runtime"
if (cd "$renamed" && runtime/setup/install_for_project.sh . --install-lumen no --lumen-index no >/dev/null 2>&1) &&
  [[ -f $renamed/.codex/agents/basix-researcher.toml && -f $renamed/.codex/agents/basix-pager.toml && -f $renamed/.codex/agents/basix-verifier.toml && ! -L $renamed/.codex/agents/basix-researcher.toml && ! -L $renamed/.codex/agents/basix-pager.toml && ! -L $renamed/.codex/agents/basix-verifier.toml ]]; then
  ok 'self-host default copy uses canonical runtime parent with relative paths'
else
  bad 'self-host default copy uses canonical runtime parent with relative paths'
fi

interactive_self="$case_dir/interactive-self"; mkdir -p "$interactive_self"; cp -R "$ROOT" "$interactive_self/src"
run_tty_default "$interactive_self/src/setup/install_for_project.sh" "$interactive_self" --install-lumen no --lumen-index no
if [[ -f $interactive_self/.codex/agents/basix-researcher.toml && -f $interactive_self/.codex/agents/basix-pager.toml && -f $interactive_self/.codex/agents/basix-verifier.toml && ! -L $interactive_self/.codex/agents/basix-researcher.toml && ! -L $interactive_self/.codex/agents/basix-pager.toml && ! -L $interactive_self/.codex/agents/basix-verifier.toml ]]; then ok 'interactive self-host default is copy'; else bad 'interactive self-host default is copy'; fi
expect 'interactive self-host does not create .basix' test ! -e "$interactive_self/.basix"

changed="$case_dir/changed"; "$ROOT/setup/install_for_project.sh" "$changed" --mode copy --install-lumen no --lumen-index no >/dev/null 2>&1
printf 'local\n' >>"$changed/.codex/agents/basix-researcher.toml"
"$ROOT/setup/install_for_project.sh" "$changed" --uninstall >/dev/null 2>&1
expect 'uninstall preserves locally changed copy' grep -q 'local' "$changed/.codex/agents/basix-researcher.toml"

relative="$case_dir/relative"; relative_target="$relative/.agents/skills/basix/SKILL.md"
mkdir -p "$(dirname "$relative_target")"
relative_source=$(realpath --relative-to="$(dirname "$relative_target")" "$ROOT/skills/basix/SKILL.md")
ln -s "$relative_source" "$relative_target"
"$ROOT/setup/install_for_project.sh" "$relative" --mode link --install-lumen no --lumen-index no >/dev/null 2>&1
relative_state=false
awk -F '\t' -v target="$relative_target" -v expected="$ROOT/skills/basix/SKILL.md" '$1 == "same" && $2 == target && $3 == expected { found = 1 } END { exit !found }' "$relative/.codex/.basix-install-state" && relative_state=true
"$ROOT/setup/install_for_project.sh" "$relative" --uninstall >/dev/null 2>&1
if [[ $relative_state == true && -L $relative_target && $(readlink "$relative_target") == "$relative_source" ]]; then ok 'relative source symlink is recorded as same and preserved'; else bad 'relative source symlink is recorded as same and preserved'; fi

redirected="$case_dir/redirected"
"$ROOT/setup/install_for_project.sh" "$redirected" --mode link --install-lumen no --lumen-index no >/dev/null 2>&1
redirected_target="$redirected/.agents/skills/basix/SKILL.md"
redirected_state=false
awk -F '\t' -v target="$redirected_target" -v expected="$ROOT/skills/basix/SKILL.md" '$1 == "link" && $2 == target && $3 == expected { found = 1 } END { exit !found }' "$redirected/.codex/.basix-install-state" && redirected_state=true
ln -sfn "$ROOT/README.md" "$redirected_target"
redirected_output="$case_dir/redirected-uninstall.out"
"$ROOT/setup/install_for_project.sh" "$redirected" --uninstall >"$redirected_output" 2>&1
if [[ $redirected_state == true && -L $redirected_target && $(readlink "$redirected_target") == "$ROOT/README.md" ]] && grep -Fq '1 preserved' "$redirected_output"; then ok 'uninstall preserves redirected managed link and reports it'; else bad 'uninstall preserves redirected managed link and reports it'; fi

loop_bundle="$case_dir/loop-bundle"; cp -R "$ROOT" "$loop_bundle"
rm "$loop_bundle/agents/native/basix-researcher.toml"
ln -s basix-researcher.toml "$loop_bundle/agents/native/basix-researcher.toml"
if "$loop_bundle/setup/install_for_project.sh" "$case_dir/loop-target" --mode link --install-lumen no --lumen-index no >/dev/null 2>&1; then bad 'symlink loop aborts preflight'; else ok 'symlink loop aborts preflight'; fi
expect 'failed preflight performs no target mutation' test ! -e "$case_dir/loop-target"

foreign="$case_dir/foreign"; mkdir -p "$foreign/.codex" "$case_dir/foreign-agents"
ln -s "$case_dir/foreign-agents" "$foreign/.codex/agents"
if "$ROOT/setup/install_for_project.sh" "$foreign" --mode link --force --install-lumen no --lumen-index no >/dev/null 2>&1; then bad 'force never replaces or traverses foreign directory link'; else ok 'force never replaces or traverses foreign directory link'; fi
expect 'foreign directory remains untouched' test -z "$(find "$case_dir/foreign-agents" -mindepth 1 -print -quit)"

unreadable_bundle="$case_dir/unreadable-bundle"; cp -R "$ROOT" "$unreadable_bundle"
chmod 000 "$unreadable_bundle/agents/native/basix-researcher.toml"
if "$unreadable_bundle/setup/install_for_project.sh" "$case_dir/unreadable-target" --mode copy --install-lumen no --lumen-index no >/dev/null 2>&1; then bad 'unreadable source aborts preflight'; else ok 'unreadable source aborts preflight'; fi
chmod 644 "$unreadable_bundle/agents/native/basix-researcher.toml"
expect 'unreadable preflight performs no target mutation' test ! -e "$case_dir/unreadable-target"

drift="$case_dir/reinstall-drift"
"$ROOT/setup/install_for_project.sh" "$drift" --mode copy --install-lumen no --lumen-index no >/dev/null 2>&1
drift_target="$drift/.codex/agents/basix-researcher.toml"
printf 'managed drift\n' > "$drift_target"
"$ROOT/setup/install_for_project.sh" "$drift" --mode copy --install-lumen no --lumen-index no >/dev/null 2>&1
expect 'reinstall resets changed managed copy' cmp -s "$ROOT/agents/native/basix-researcher.toml" "$drift_target"

cyclic="$case_dir/reinstall-cycle"
"$ROOT/setup/install_for_project.sh" "$cyclic" --mode link --install-lumen no --lumen-index no >/dev/null 2>&1
cyclic_target="$cyclic/.codex/agents/basix-researcher.toml"
ln -sfn "$cyclic_target" "$cyclic_target"
"$ROOT/setup/install_for_project.sh" "$cyclic" --mode link --install-lumen no --lumen-index no >/dev/null 2>&1
expect 'reinstall replaces cyclic managed link without resolving it' test "$(readlink "$cyclic_target")" = "$ROOT/agents/native/basix-researcher.toml"

directory_cycle="$case_dir/directory-cycle"; mkdir -p "$directory_cycle"
cp -R "$ROOT" "$directory_cycle/src"
mkdir -p "$directory_cycle/.codex" "$directory_cycle/.agents/skills"
ln -s "$directory_cycle/src/agents/native" "$directory_cycle/.codex/agents"
for skill in "$directory_cycle"/src/skills/*; do ln -s "$skill" "$directory_cycle/.agents/skills/${skill##*/}"; done
"$directory_cycle/src/setup/install_for_project.sh" "$directory_cycle" --mode copy --install-lumen no --lumen-index no >/dev/null 2>&1
rm -rf "$directory_cycle/.codex/agents"
ln -s agents "$directory_cycle/.codex/agents"
"$directory_cycle/src/setup/install_for_project.sh" "$directory_cycle" --mode link --install-lumen no --lumen-index no >/dev/null 2>&1
if [[ -d $directory_cycle/.codex/agents && ! -L $directory_cycle/.codex/agents &&
  -L $directory_cycle/.codex/agents/basix-researcher.toml ]]; then
  ok 'reinstall detaches cyclic managed directory link before writing'
else
  bad 'reinstall detaches cyclic managed directory link before writing'
fi

legacy="$case_dir/legacy-bundle"; mkdir -p "$legacy/.codex" "$legacy/.agents/skills/basix" "$legacy/.codex/agents"
cp -R "$ROOT" "$legacy/.basix"
legacy_hash='legacy-bundle-hash'
ln -s "$legacy/.basix/skills/basix/SKILL.md" "$legacy/.agents/skills/basix/SKILL.md"
ln -s "$legacy/.basix/agents/native/basix-researcher.toml" "$legacy/.codex/agents/basix-researcher.toml"
printf 'bundle-copy\t%s\t%s\nlink\t%s\t%s\nlink\t%s\t%s\n' \
  "$legacy/.basix" "$legacy_hash" \
  "$legacy/.agents/skills/basix/SKILL.md" "$legacy/.basix/skills/basix/SKILL.md" \
  "$legacy/.codex/agents/basix-researcher.toml" "$legacy/.basix/agents/native/basix-researcher.toml" > "$legacy/.codex/.basix-install-state"
printf 'memory\n' > "$legacy/.basix/memory.md"
printf 'credentials\n' > "$legacy/.basix/credentials.md"
printf 'foreign\n' > "$legacy/.basix/project-note.txt"
mkdir -p "$legacy/.basix/project-cache/__pycache__"
printf 'foreign-cache\n' > "$legacy/.basix/project-cache/__pycache__/foreign.pyc"
before_memory=$(sha256sum "$legacy/.basix/memory.md" "$legacy/.basix/credentials.md" "$legacy/.basix/project-note.txt")
"$ROOT/setup/install_for_project.sh" "$legacy" --mode link --install-lumen no --lumen-index no >/dev/null 2>&1
after_memory=$(sha256sum "$legacy/.basix/memory.md" "$legacy/.basix/credentials.md" "$legacy/.basix/project-note.txt")
if [[ $before_memory == "$after_memory" && -f $legacy/.basix/project-cache/__pycache__/foreign.pyc &&
  ! -e $legacy/.basix/skills && ! -e $legacy/.basix/agents &&
  $(readlink "$legacy/.agents/skills/basix/SKILL.md") == "$ROOT/skills/basix/SKILL.md" &&
  $(readlink "$legacy/.codex/agents/basix-researcher.toml") == "$ROOT/agents/native/basix-researcher.toml" ]] &&
  ! grep -Eq '^bundle-(copy|link)[[:space:]]' "$legacy/.codex/.basix-install-state"; then
  ok 'legacy bundle migrates to direct links and preserves project-owned .basix files'
else
  bad 'legacy bundle migrates to direct links and preserves project-owned .basix files'
fi

stale="$case_dir/stale-managed"
"$ROOT/setup/install_for_project.sh" "$stale" --mode copy --install-lumen no --lumen-index no >/dev/null 2>&1
stale_target="$stale/.agents/skills/basix/obsolete.pyc"
printf 'old cache\n' > "$stale_target"
printf 'copy\t%s\t%s\n' "$stale_target" "$(sha256sum "$stale_target" | awk '{print $1}')" >> "$stale/.codex/.basix-install-state"
"$ROOT/setup/install_for_project.sh" "$stale" --mode copy --install-lumen no --lumen-index no >/dev/null 2>&1
expect 'reinstall removes stale managed cache target' test ! -e "$stale_target"

git_guard="$case_dir/git-guard"; mkdir -p "$git_guard/bin"
cat > "$git_guard/bin/git" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
chmod +x "$git_guard/bin/git"
expect 'core project installer performs no Git operation' env PATH="$git_guard/bin:$PATH" "$ROOT/setup/install_for_project.sh" "$git_guard/project" --mode link --install-lumen no --lumen-index no

printf '%d passed, %d failed\n' "$passes" "$failures"
((failures == 0))

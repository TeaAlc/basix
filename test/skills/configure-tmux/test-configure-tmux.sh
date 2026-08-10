#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/src
SKILL=$ROOT/skills/configure-tmux
CONFIGURE=$SKILL/scripts/configure-tmux.sh
DIAGNOSE=$SKILL/scripts/diagnose-tmux.sh
VERIFY=$SKILL/scripts/verify-tmux.sh
CLIPBOARD=$SKILL/scripts/tmux-clipboard-paste.sh
REAL_TMUX=$(command -v tmux || true)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/basix-test-configure-tmux.XXXXXX")
runtime_socket_dir=
runtime_socket_name=
cleanup() {
  if [[ -n $runtime_socket_dir && -n $runtime_socket_name ]]; then
    TMUX='' TMUX_TMPDIR=$runtime_socket_dir tmux -L "$runtime_socket_name" kill-server >/dev/null 2>&1 || true
  fi
  rm -rf -- "$TEMP"
}
trap cleanup EXIT HUP INT TERM
export TMUX=''

ok() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
check() { "$@" || bad "$*"; }
expect_fail() {
  local expected=$1; shift
  set +e
  "$@" >"$TEMP/failure.out" 2>"$TEMP/failure.err"
  local status=$?
  set -e
  [[ $status == "$expected" ]] || { printf 'expected exit %s, got %s\n' "$expected" "$status" >&2; sed -n '1,80p' "$TEMP/failure.err" >&2; return 1; }
}

for file in "$CONFIGURE" "$DIAGNOSE" "$VERIFY" "$CLIPBOARD"; do
  [[ -x $file ]] || bad "$file is not executable"
  bash -n "$file"
done
ok 'skill scripts are executable and parse as Bash'

home_space=$TEMP/'home with space'
mkdir -p "$home_space"
dry_output=$TEMP/dry.out
HOME=/nonexistent XDG_CONFIG_HOME='' "$CONFIGURE" --mode tmux-mouse --target-home "$home_space" >"$dry_output"
[[ ! -e $home_space/.config/tmux/tmux.conf ]] || bad 'dry-run wrote an entry config'
grep -Fq 'Dry-run only' "$dry_output" || bad 'dry-run notice missing'
grep -Fq '@@ -0,0 +1,3 @@' "$dry_output" || bad 'zero-context entry diff missing'
HOME=/nonexistent XDG_CONFIG_HOME='' "$CONFIGURE" --mode tmux-mouse --target-home "$home_space" --apply >/dev/null
entry=$home_space/.config/tmux/tmux.conf
fragment=$home_space/.config/tmux/conf.d/basix-terminal.conf
helper=$home_space/.config/tmux/bin/basix-clipboard-paste
check grep -Fq 'source-file "' "$entry"
[[ $(grep -Fxc '# >>> basix configure-tmux >>>' "$entry") == 1 ]] || bad 'source marker is not unique'
check grep -Fq 'set-option -g mouse on' "$fragment"
check grep -Fxq '# Basix configure-tmux schema=2' "$fragment"
check grep -Fxq 'set-option -s extended-keys on' "$fragment"
check grep -Fxq "set-option -s 'terminal-features[1000]' 'xterm*:extkeys'" "$fragment"
[[ -x $helper ]] || bad 'managed helper is not executable'
first_hash=$(sha256sum "$entry" "$fragment" "$helper")
HOME=/nonexistent XDG_CONFIG_HOME='' "$CONFIGURE" --mode tmux-mouse --target-home "$home_space" --apply >"$TEMP/idempotent.out"
[[ $(sha256sum "$entry" "$fragment" "$helper") == "$first_hash" ]] || bad 'second apply changed managed files'
! grep -q '^--- ' "$TEMP/idempotent.out" || bad 'idempotent apply emitted a diff'
ok 'fresh home, spaces, dry-run, apply, and idempotency'

for generated_mode in tmux-mouse native-terminal keyboard-only; do
  generated_home=$TEMP/generated-$generated_mode
  mkdir -p "$generated_home"
  HOME=$generated_home XDG_CONFIG_HOME='' "$CONFIGURE" --mode "$generated_mode" --target-home "$generated_home" --apply >/dev/null
  generated_fragment=$generated_home/.config/tmux/conf.d/basix-terminal.conf
  [[ $(grep -Fxc 'set-option -s extended-keys on' "$generated_fragment") == 1 ]] || bad "$generated_mode extended-keys definition missing or duplicated"
  [[ $(grep -Fxc "set-option -s 'terminal-features[1000]' 'xterm*:extkeys'" "$generated_fragment") == 1 ]] || bad "$generated_mode terminal feature missing or duplicated"
done
ok 'all modes generate schema-2 extended-key transport exactly once'

for unusual in 'home\backslash' 'home"quote'; do
  unusual_home=$TEMP/$unusual
  mkdir -p "$unusual_home"
  HOME=/nonexistent XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$unusual_home" --apply >/dev/null
  HOME=/nonexistent XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$unusual_home" --apply >"$TEMP/unusual-second.out"
  ! grep -q '^--- ' "$TEMP/unusual-second.out" || bad "second apply changed the $unusual path"
  HOME=/nonexistent XDG_CONFIG_HOME='' "$CONFIGURE" --mode tmux-mouse --target-home "$unusual_home" --apply >/dev/null
  grep -Fq 'set-option -g mouse on' "$unusual_home/.config/tmux/conf.d/basix-terminal.conf" || bad "mode switch failed for $unusual path"
done
ok 'backslash and double-quote paths remain idempotent'

legacy_home=$TEMP/legacy
mkdir -p "$legacy_home"
printf '%s\n' 'set-option -g status off' >"$legacy_home/.tmux.conf"
chmod 640 "$legacy_home/.tmux.conf"
HOME=$legacy_home XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$legacy_home" --apply >/dev/null
grep -Fq 'set-option -g status off' "$legacy_home/.tmux.conf" || bad 'legacy content was not preserved'
[[ $(stat -c '%a' "$legacy_home/.tmux.conf") == 640 ]] || bad 'entry permissions were not preserved'
printf '%s\n' '# user changed this' >>"$legacy_home/.tmux.conf"
HOME=$legacy_home XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$legacy_home" --history-limit 60000 --apply >/dev/null
compgen -G "$legacy_home/.tmux.conf.basix-backup.*" >/dev/null || bad 'entry backup missing'
compgen -G "$legacy_home/.config/tmux/conf.d/basix-terminal.conf.basix-backup.*" >/dev/null || bad 'fragment backup missing'
ok 'legacy entry, preservation, permissions, and backups'

schema1_home=$TEMP/schema1
schema1_fragment=$schema1_home/.config/tmux/conf.d/basix-terminal.conf
mkdir -p "${schema1_fragment%/*}"
printf '%s\n' '# >>> basix configure-tmux >>>' "source-file \"$schema1_fragment\"" '# <<< basix configure-tmux <<<' >"$schema1_home/.tmux.conf"
printf '%s\n' '# Basix configure-tmux schema=1' '# mode=keyboard-only' '# managed-bindings=none' 'set-option -g history-limit 50000' 'set-option -g mouse off' >"$schema1_fragment"
HOME=$schema1_home XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$schema1_home" --apply >/dev/null
grep -Fxq '# Basix configure-tmux schema=2' "$schema1_fragment" || bad 'schema-1 fragment was not migrated'
compgen -G "$schema1_fragment.basix-backup.*" >/dev/null || bad 'schema-1 migration backup missing'
schema2_hash=$(sha256sum "$schema1_fragment")
HOME=$schema1_home XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$schema1_home" --apply >"$TEMP/schema2-repeat.out"
[[ $(sha256sum "$schema1_fragment") == "$schema2_hash" ]] || bad 'schema-2 repeat apply changed fragment'
! grep -q '^--- ' "$TEMP/schema2-repeat.out" || bad 'schema-2 repeat apply emitted a diff'
ok 'schema-1 fragments migrate with backup and remain idempotent'

both_home=$TEMP/both
mkdir -p "$both_home/.config/tmux"
: >"$both_home/.tmux.conf"; : >"$both_home/.config/tmux/tmux.conf"
expect_fail 2 env HOME="$both_home" XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$both_home"
HOME=$both_home XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$both_home" --entry-config "$both_home/.tmux.conf" --apply >/dev/null
ok 'conflicting standard entries require explicit selection'

conflict_home=$TEMP/conflicts
mkdir -p "$conflict_home/.config/tmux/conf.d"
printf '%s\n' '# >>> basix configure-tmux >>>' >"$conflict_home/.tmux.conf"
expect_fail 2 env HOME="$conflict_home" XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$conflict_home"
printf '%s\n' '# foreign' >"$conflict_home/.config/tmux/conf.d/basix-terminal.conf"
printf '%s\n' '# ordinary' >"$conflict_home/.tmux.conf"
expect_fail 2 env HOME="$conflict_home" XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$conflict_home"
rm -f "$conflict_home/.config/tmux/conf.d/basix-terminal.conf"
HOME=$conflict_home XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$conflict_home" --apply >/dev/null
printf '%s\n' '# foreign trailing line' >>"$conflict_home/.config/tmux/conf.d/basix-terminal.conf"
expect_fail 2 env HOME="$conflict_home" XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$conflict_home"
rm -f "$conflict_home/.config/tmux/conf.d/basix-terminal.conf"
ln -s "$TEMP/elsewhere" "$conflict_home/.config/tmux/conf.d/basix-terminal.conf"
expect_fail 2 env HOME="$conflict_home" XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$conflict_home"
rm -f "$conflict_home/.config/tmux/conf.d/basix-terminal.conf"
printf "%s\n" "set-option -g 'terminal-overrides[1000]' foreign" >"$conflict_home/.tmux.conf"
expect_fail 2 env HOME="$conflict_home" XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$conflict_home"
printf "%s\n" "set-option -s 'terminal-features[1000]' foreign" >"$conflict_home/.tmux.conf"
expect_fail 2 env HOME="$conflict_home" XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$conflict_home" --apply
[[ ! -e $conflict_home/.config/tmux/conf.d/basix-terminal.conf ]] || bad 'foreign terminal feature caused a fragment write'
ok 'markers, foreign content, symlinks, and reserved index fail closed'

fake=$TEMP/fake
mkdir -p "$fake/bin"
expected=$fake/expected
loaded=$fake/loaded
tmux_log=$fake/tmux.log
printf 'line one\nspecial $* []\n\n' >"$expected"
cat >"$fake/bin/wl-paste" <<'EOF'
#!/usr/bin/env bash
printf 'line one\nspecial $* []\n\n'
EOF
cat >"$fake/bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
case ${1:-} in
  load-buffer)
    for argument in "$@"; do source_file=$argument; done
    cp -- "$source_file" "$FAKE_LOADED"
    ;;
  list-buffers) printf '%s\n' existing ;;
  paste-buffer|delete-buffer) ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$fake/bin/wl-paste" "$fake/bin/tmux"
PATH=$fake/bin:/usr/bin WAYLAND_DISPLAY=wayland-0 DISPLAY='' TMUX_BIN=$fake/bin/tmux FAKE_TMUX_LOG=$tmux_log FAKE_LOADED=$loaded "$CLIPBOARD" %7 auto >"$fake/stdout" 2>"$fake/stderr"
cmp "$expected" "$loaded" || bad 'clipboard bytes or trailing newlines changed'
[[ ! -s $fake/stdout && ! -s $fake/stderr ]] || bad 'successful clipboard paste logged output'
! grep -Fq 'special $*' "$tmux_log" || bad 'clipboard content leaked into tmux arguments'

for transport in xclip xsel; do
  cat >"$fake/bin/$transport" <<'EOF'
#!/usr/bin/env bash
printf 'line one\nspecial $* []\n\n'
EOF
  chmod +x "$fake/bin/$transport"
  PATH=$fake/bin:/usr/bin WAYLAND_DISPLAY='' DISPLAY=:1 TMUX_BIN=$fake/bin/tmux FAKE_TMUX_LOG=$tmux_log FAKE_LOADED=$loaded "$CLIPBOARD" %7 "$transport" >/dev/null
  cmp "$expected" "$loaded" || bad "$transport clipboard bytes changed"
done

cat >"$fake/bin/wl-paste" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake/bin/wl-paste"
expect_fail 1 env PATH="$fake/bin:/usr/bin" WAYLAND_DISPLAY=wayland-0 DISPLAY='' TMUX_BIN="$fake/bin/tmux" FAKE_TMUX_LOG="$tmux_log" FAKE_LOADED="$loaded" "$CLIPBOARD" %7 auto
grep -Fq 'pasted the current tmux buffer' "$TEMP/failure.err" || bad 'empty clipboard fallback warning missing'
expect_fail 1 env PATH="$fake/bin:/usr/bin" WAYLAND_DISPLAY='' DISPLAY='' TMUX_BIN="$fake/bin/tmux" FAKE_TMUX_LOG="$tmux_log" FAKE_LOADED="$loaded" "$CLIPBOARD" %7 wl-paste
ok 'clipboard transports preserve bytes, stay content-free, and warn on fallback'

quote_home=$TEMP/quoted-xdg
mkdir -p "$quote_home"
expect_fail 2 env PATH="$fake/bin:/usr/bin" HOME="$quote_home" XDG_CONFIG_HOME="$quote_home/xdg'bad" WAYLAND_DISPLAY=wayland-0 DISPLAY='' "$CONFIGURE" --mode tmux-mouse --clipboard-helper wl-paste --apply
[[ ! -e "$quote_home/xdg'bad" ]] || bad 'unsafe quoted XDG helper path caused a write'
grep -Fq 'shell-sensitive characters' "$TEMP/failure.err" || bad 'unsafe helper path reason missing'
ok 'shell-sensitive XDG helper paths fail before generation'

write_home=$TEMP/write-failure
mkdir -p "$write_home"
printf '%s\n' '# keep me' >"$write_home/.tmux.conf"
chmod 500 "$write_home"
expect_fail 2 env HOME="$write_home" XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$write_home" --apply
chmod 700 "$write_home"
[[ $(<"$write_home/.tmux.conf") == '# keep me' ]] || bad 'failed atomic apply changed the entry config'
ok 'write failure leaves the existing entry config intact'

probe_fake=$TEMP/probe-fake-tmux
cat >"$probe_fake" <<'EOF'
#!/usr/bin/env bash
if [[ $* == *'new-session -d'* || $* == *kill-server* ]]; then exit 0; fi
if [[ $* == *'set-option -s extended-keys on'* ]]; then [[ ${PROBE_FAIL:-} != extended ]]; exit; fi
if [[ $* == *terminal-features* ]]; then [[ ${PROBE_FAIL:-} != array ]]; exit; fi
exit 0
EOF
chmod +x "$probe_fake"
for probe_failure in extended array; do
  probe_home=$TEMP/probe-failure-$probe_failure
  mkdir -p "$probe_home"
  expect_fail 2 env HOME="$probe_home" XDG_CONFIG_HOME='' TMUX_BIN="$probe_fake" PROBE_FAIL="$probe_failure" "$CONFIGURE" --mode keyboard-only --target-home "$probe_home" --apply
  [[ ! -e $probe_home/.config/tmux/tmux.conf ]] || bad "$probe_failure syntax failure wrote an entry config"
  [[ ! -e $probe_home/.config/tmux/conf.d/basix-terminal.conf ]] || bad "$probe_failure syntax failure wrote a fragment"
done
ok 'extended-key and array syntax failures stop before every write'

reload_home=$TEMP/unreachable-reload
mkdir -p "$reload_home"
expect_fail 1 env HOME="$reload_home" XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$reload_home" --socket-name no-such-basix-reload --apply --reload
[[ ! -e $reload_home/.config/tmux/tmux.conf ]] || bad 'unreachable reload changed files before preflight'
ok 'unreachable live reload fails before file changes'

set +e
HOME=$home_space XDG_CONFIG_HOME='' TERM=dumb "$DIAGNOSE" --format text --target-home "$home_space" --socket-name no-such-basix-socket >"$TEMP/diagnose.text"
text_status=$?
HOME=$home_space XDG_CONFIG_HOME='' TERM=dumb "$DIAGNOSE" --format json --target-home "$home_space" --socket-name no-such-basix-socket >"$TEMP/diagnose.json"
json_status=$?
set -e
[[ $text_status == "$json_status" && $text_status == 1 ]] || bad 'diagnosis formats returned different status'
grep -Fq 'overall_status=warning' "$TEMP/diagnose.text" || bad 'text warning status missing'
PYTHONDONTWRITEBYTECODE=1 python3 - "$TEMP/diagnose.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema_version"] == 1
assert data["overall_status"] == "warning"
assert data["context"]["server_reachable"] is False
assert isinstance(data["checks"], list) and data["manual_checks"]
for forbidden in ("clipboard_content", "environment", "shell_profile"):
    assert forbidden not in data
PY
ok 'text and JSON diagnosis share stable warning status'

control_term=$'bad\001\b\f\037\177term'
set +e
HOME=$home_space XDG_CONFIG_HOME='' TERM=$control_term "$DIAGNOSE" --format json --target-home "$home_space" --socket-name no-such-basix-socket >"$TEMP/diagnose-controls.json"
control_status=$?
set -e
[[ $control_status == 1 ]] || bad 'control-character diagnosis did not return warning'
PYTHONDONTWRITEBYTECODE=1 python3 - "$TEMP/diagnose-controls.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["context"]["terminal"].startswith("bad")
PY

symlink_home=$TEMP/diagnose-symlink
mkdir -p "$symlink_home"
printf '%s\n' '# target' >"$TEMP/symlink-target"
ln -s "$TEMP/symlink-target" "$symlink_home/.tmux.conf"
set +e
HOME=$symlink_home XDG_CONFIG_HOME='' "$DIAGNOSE" --format text --target-home "$symlink_home" --socket-name no-such-basix-socket >"$TEMP/diagnose-symlink.out"
symlink_status=$?
set -e
[[ $symlink_status == 1 ]] || bad 'symlink diagnosis did not warn'
grep -Fq 'entry config is a symlink' "$TEMP/diagnose-symlink.out" || bad 'standard config symlink was not diagnosed'
ok 'JSON controls and standard config symlinks are diagnosed safely'

diagnose_fake_dir=$TEMP/diagnose-fake/bin
mkdir -p "$diagnose_fake_dir"
cat >"$diagnose_fake_dir/tmux" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  '-V') printf '%s\n' 'tmux fake' ;;
  *'list-clients -F #{client_tty}|#{client_termfeatures}'*) printf '%s\n' "${DIAG_FEATURE_LINES:-}" ;;
  *'list-clients -F #{client_tty}'*)
    while IFS='|' read -r tty _; do [[ -z $tty ]] || printf '%s\n' "$tty"; done <<<"${DIAG_FEATURE_LINES:-}"
    ;;
  *'list-clients'*) exit 0 ;;
  *'show-options -gv mouse'*) printf '%s\n' on ;;
  *'show-options -gv history-limit'*) printf '%s\n' 50000 ;;
  *'show-options -sv extended-keys'*) printf '%s\n' "${DIAG_EXTENDED_KEYS:-unknown}" ;;
  *'list-panes'*) printf '%s\n' '0 0' ;;
  *'display-message'*) printf '%s\n' "${DIAG_ENTRY:-}" ;;
  *'list-keys -T root'*) printf '%s\n' 'bind-key -T root C-c send-keys C-c' 'bind-key -T root C-Enter send-keys Enter' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$diagnose_fake_dir/tmux"
for client_case in enabled disabled mixed missing; do
  case $client_case in
    enabled) feature_lines='/dev/pts/1|RGB,extkeys'; extended_value=on ;;
    disabled) feature_lines='/dev/pts/1|RGB'; extended_value=off ;;
    mixed) feature_lines=$'/dev/pts/1|RGB,extkeys\n/dev/pts/2|RGB'; extended_value=on ;;
    missing) feature_lines=''; extended_value=unknown ;;
  esac
  for diagnose_format in text json; do
    set +e
    PATH=$diagnose_fake_dir:/usr/bin DIAG_FEATURE_LINES="$feature_lines" DIAG_EXTENDED_KEYS=$extended_value DIAG_ENTRY=$entry HOME=$home_space XDG_CONFIG_HOME='' TERM=dumb "$DIAGNOSE" --format "$diagnose_format" --target-home "$home_space" --entry-config "$entry" >"$TEMP/diagnose-$client_case.$diagnose_format"
    diagnose_status=$?
    set -e
    [[ $diagnose_status == 1 ]] || bad "$client_case $diagnose_format diagnosis did not return warning"
  done
  grep -Fq "client_extkeys_status=$client_case" "$TEMP/diagnose-$client_case.text" || bad "$client_case text client status missing"
  grep -Fq 'possible_root_binding=bind-key -T root C-Enter' "$TEMP/diagnose-$client_case.text" || bad "$client_case text modified-key binding missing"
  PYTHONDONTWRITEBYTECODE=1 python3 - "$TEMP/diagnose-$client_case.json" "$client_case" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema_version"] == 1
assert data["context"]["client_extkeys_status"] == sys.argv[2]
assert any("C-Enter" in binding for binding in data["possible_root_bindings"])
if sys.argv[2] == "mixed":
    assert data["client_extkeys"] == ["/dev/pts/1:enabled", "/dev/pts/2:disabled"]
PY
done
ok 'text and JSON diagnose enabled, disabled, missing, and mixed client extkeys support'

runtime_dir=$TEMP/runtime-probe
mkdir -p "$runtime_dir"
runtime_available=false
if command -v tmux >/dev/null 2>&1 && TMUX='' TMUX_TMPDIR=$runtime_dir tmux -L basix-test-probe-$$ -f /dev/null new-session -d 2>/dev/null; then
  runtime_available=true
  TMUX='' TMUX_TMPDIR=$runtime_dir tmux -L basix-test-probe-$$ kill-server >/dev/null 2>&1 || true
fi
if $runtime_available; then
  "$VERIFY"
  switch_home=$TEMP/switch
  mkdir -p "$switch_home"
  HOME=$switch_home XDG_CONFIG_HOME='' "$CONFIGURE" --mode native-terminal --target-home "$switch_home" --apply >/dev/null
  grep -Fq "terminal-overrides[1000]" "$switch_home/.config/tmux/conf.d/basix-terminal.conf" || bad 'native override missing'
  HOME=$switch_home XDG_CONFIG_HOME='' "$CONFIGURE" --mode native-terminal --target-home "$switch_home" --apply >"$TEMP/native-twice.out"
  [[ $(grep -Fc "terminal-overrides[1000]" "$switch_home/.config/tmux/conf.d/basix-terminal.conf") == 1 ]] || bad 'native override duplicated'
  HOME=$switch_home XDG_CONFIG_HOME='' "$CONFIGURE" --mode keyboard-only --target-home "$switch_home" --apply >/dev/null
  ! grep -Fq "terminal-overrides[1000]" "$switch_home/.config/tmux/conf.d/basix-terminal.conf" || bad 'old native override remained in file'
  runtime_socket_dir=$TEMP/live-socket
  runtime_socket_name=basix-live-$$
  mkdir -p "$runtime_socket_dir"
  TMUX='' TMUX_TMPDIR=$runtime_socket_dir tmux -L "$runtime_socket_name" -f /dev/null new-session -d
  live_entry=$switch_home/.config/tmux/tmux.conf
  HOME=$switch_home XDG_CONFIG_HOME='' TMUX_TMPDIR=$runtime_socket_dir "$CONFIGURE" --mode keyboard-only --target-home "$switch_home" --entry-config "$live_entry" --socket-name "$runtime_socket_name" --apply --reload >/dev/null
  HOME=$switch_home XDG_CONFIG_HOME='' TMUX_TMPDIR=$runtime_socket_dir "$VERIFY" --live --target-home "$switch_home" --entry-config "$live_entry" --socket-name "$runtime_socket_name" >/dev/null
  live_fragment=$switch_home/.config/tmux/conf.d/basix-terminal.conf
  live_hash=$(sha256sum "$live_entry" "$live_fragment")
  TMUX='' TMUX_TMPDIR=$runtime_socket_dir tmux -L "$runtime_socket_name" set-option -s 'terminal-features[1000]' foreign
  expect_fail 2 env HOME="$switch_home" XDG_CONFIG_HOME='' TMUX_TMPDIR="$runtime_socket_dir" "$CONFIGURE" --mode keyboard-only --history-limit 60001 --target-home "$switch_home" --entry-config "$live_entry" --socket-name "$runtime_socket_name" --apply --reload
  [[ $(sha256sum "$live_entry" "$live_fragment") == "$live_hash" ]] || bad 'foreign live terminal feature changed files before refusal'
  TMUX='' TMUX_TMPDIR=$runtime_socket_dir tmux -L "$runtime_socket_name" set-option -s 'terminal-features[1000]' 'xterm*:extkeys'
  HOME=$switch_home XDG_CONFIG_HOME='' TMUX_TMPDIR=$runtime_socket_dir "$CONFIGURE" --mode keyboard-only --target-home "$switch_home" --entry-config "$live_entry" --socket-name "$runtime_socket_name" --apply --reload >"$TEMP/reload-once.out"
  HOME=$switch_home XDG_CONFIG_HOME='' TMUX_TMPDIR=$runtime_socket_dir "$CONFIGURE" --mode keyboard-only --target-home "$switch_home" --entry-config "$live_entry" --socket-name "$runtime_socket_name" --apply --reload >"$TEMP/reload-twice.out"
  [[ $(TMUX='' TMUX_TMPDIR=$runtime_socket_dir tmux -L "$runtime_socket_name" show-options -s | grep -Fc 'terminal-features[1000] xterm*:extkeys') == 1 ]] || bad 'repeated reload duplicated the terminal feature'
  grep -Fq 'detach and reattach clients so extended-key terminal capabilities are renegotiated' "$TEMP/reload-twice.out" || bad 'extended-key reconnect note missing'
  TMUX='' TMUX_TMPDIR=$runtime_socket_dir tmux -L "$runtime_socket_name" set-option -g 'terminal-overrides[1000]' foreign
  expect_fail 2 env HOME="$switch_home" XDG_CONFIG_HOME='' TMUX_TMPDIR="$runtime_socket_dir" "$CONFIGURE" --mode native-terminal --target-home "$switch_home" --entry-config "$live_entry" --socket-name "$runtime_socket_name"
  TMUX='' TMUX_TMPDIR=$runtime_socket_dir tmux -L "$runtime_socket_name" set-option -gu 'terminal-overrides[1000]'
  HOME=$switch_home XDG_CONFIG_HOME='' TMUX_TMPDIR=$runtime_socket_dir "$CONFIGURE" --mode native-terminal --target-home "$switch_home" --entry-config "$live_entry" --socket-name "$runtime_socket_name" --apply --reload >/dev/null
  [[ $(TMUX='' TMUX_TMPDIR=$runtime_socket_dir tmux -L "$runtime_socket_name" show-options -gv 'terminal-overrides[1000]') == 'xterm*:smcup@:rmcup@' ]] || bad 'live native override was not applied'
  HOME=$switch_home XDG_CONFIG_HOME='' TMUX_TMPDIR=$runtime_socket_dir "$CONFIGURE" --mode keyboard-only --target-home "$switch_home" --entry-config "$live_entry" --socket-name "$runtime_socket_name" --apply --reload >/dev/null
  [[ -z $(TMUX='' TMUX_TMPDIR=$runtime_socket_dir tmux -L "$runtime_socket_name" show-options -gv 'terminal-overrides[1000]' 2>/dev/null || true) ]] || bad 'live Basix native override was not removed'
  TMUX='' TMUX_TMPDIR=$runtime_socket_dir tmux -L "$runtime_socket_name" kill-server >/dev/null

  helper_home=$TEMP/live-helper-home
  mkdir -p "$helper_home"
  PATH=$fake/bin:/usr/bin WAYLAND_DISPLAY=wayland-0 HOME=$helper_home XDG_CONFIG_HOME='' TMUX_BIN=$REAL_TMUX "$CONFIGURE" --mode tmux-mouse --clipboard-helper wl-paste --target-home "$helper_home" --apply >/dev/null
  helper_entry=$helper_home/.config/tmux/tmux.conf
  runtime_socket_name=basix-helper-live-$$
  TMUX='' TMUX_TMPDIR=$runtime_socket_dir tmux -L "$runtime_socket_name" -f "$helper_entry" new-session -d
  TMUX='' TMUX_TMPDIR=$runtime_socket_dir tmux -L "$runtime_socket_name" list-keys -T root MouseDown3Pane | grep -Fq basix-clipboard-paste || bad 'managed live mouse binding was not loaded'
  HOME=$helper_home XDG_CONFIG_HOME='' TMUX_TMPDIR=$runtime_socket_dir "$CONFIGURE" --mode tmux-mouse --clipboard-helper disabled --target-home "$helper_home" --entry-config "$helper_entry" --socket-name "$runtime_socket_name" --apply --reload >/dev/null
  if TMUX='' TMUX_TMPDIR=$runtime_socket_dir tmux -L "$runtime_socket_name" list-keys -T root MouseDown3Pane >/dev/null 2>&1; then bad 'known Basix mouse binding was not removed'; fi
  TMUX='' TMUX_TMPDIR=$runtime_socket_dir tmux -L "$runtime_socket_name" kill-server >/dev/null
  runtime_socket_dir=
  runtime_socket_name=
  ok 'isolated and live tmux runtime verifies modes, reloads, bindings, and foreign index refusal'
else
  printf 'SKIP: tmux isolated sockets are unavailable; runtime mode tests skipped.\n'
fi

printf 'configure-tmux tests passed.\n'

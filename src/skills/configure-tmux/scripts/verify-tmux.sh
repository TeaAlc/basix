#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: verify-tmux.sh [--live] [--target-home PATH] [--entry-config PATH]
                      [--socket-name NAME | --socket-path PATH]
EOF
}
fail() { printf 'verify-tmux: %s\n' "$1" >&2; exit "${2:-2}"; }

live=false
target_home=
entry_config=
socket_name=
socket_path=
while (( $# )); do
  case $1 in
    --target-home|--entry-config|--socket-name|--socket-path)
      (( $# >= 2 )) || fail "missing value for $1" 64
      case $1 in
        --target-home) target_home=$2 ;;
        --entry-config) entry_config=$2 ;;
        --socket-name) socket_name=$2 ;;
        --socket-path) socket_path=$2 ;;
      esac
      shift 2 ;;
    --live) live=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" 64 ;;
  esac
done
[[ -z $socket_name || -z $socket_path ]] || fail "--socket-name and --socket-path are mutually exclusive" 64
command -v tmux >/dev/null 2>&1 || { printf 'SKIP: tmux is not installed; runtime verification is unavailable.\n'; exit 1; }

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
configure=$script_dir/configure-tmux.sh

if $live; then
  if [[ -z $target_home ]]; then [[ -n ${HOME:-} ]] || fail "HOME is unset; use --target-home"; target_home=$HOME; fi
  if [[ -z ${XDG_CONFIG_HOME:-} || $target_home != "${HOME:-}" ]]; then config_home=$target_home/.config; else config_home=$XDG_CONFIG_HOME; fi
  fragment=$config_home/tmux/conf.d/basix-terminal.conf
  [[ -f $fragment && ! -L $fragment ]] || fail "managed fragment is missing or unsafe"
  if [[ -n $entry_config ]]; then
    [[ -f $entry_config && ! -L $entry_config ]] || fail "explicit entry config is missing or unsafe"
    grep -Fq "source-file \"$fragment\"" "$entry_config" || fail "explicit entry config does not source the managed fragment" 1
  fi
  IFS= read -r first <"$fragment" || true
  [[ $first == '# Basix configure-tmux schema=2' ]] || fail "managed fragment has an unsupported header"
  mode=$(sed -n 's/^# mode=//p' "$fragment" | head -n1)
  expected_history=$(sed -n 's/^set-option -g history-limit //p' "$fragment" | head -n1)
  server_args=()
  if [[ -n $socket_name ]]; then server_args=(-L "$socket_name")
  elif [[ -n $socket_path ]]; then server_args=(-S "$socket_path")
  elif [[ -z ${TMUX:-} ]]; then fail "--live requires an explicit socket or active TMUX environment" 64; fi
  tmux "${server_args[@]}" list-clients >/dev/null 2>&1 || fail "selected live server is unreachable" 1
  actual_mouse=$(tmux "${server_args[@]}" show-options -gv mouse)
  actual_history=$(tmux "${server_args[@]}" show-options -gv history-limit)
  actual_extended_keys=$(tmux "${server_args[@]}" show-options -sv extended-keys 2>/dev/null || true)
  actual_extkeys_feature=$(tmux "${server_args[@]}" show-options -sv 'terminal-features[1000]' 2>/dev/null || true)
  [[ $actual_history == "$expected_history" ]] || fail "live history-limit differs from the managed fragment" 1
  [[ $actual_extended_keys == on ]] || fail "live extended-keys option is not on" 1
  [[ $actual_extkeys_feature == 'xterm*:extkeys' ]] || fail "live terminal feature differs" 1
  if [[ $mode == tmux-mouse ]]; then [[ $actual_mouse == on ]] || fail "live mouse option is off" 1
  else [[ $actual_mouse == off ]] || fail "live mouse option is on" 1; fi
  if [[ $mode == native-terminal ]]; then
    [[ $(tmux "${server_args[@]}" show-options -gv 'terminal-overrides[1000]' 2>/dev/null || true) == 'xterm*:smcup@:rmcup@' ]] || fail "live terminal override differs" 1
  fi
  printf 'Live tmux configuration verified read-only: mode=%s history-limit=%s.\n' "$mode" "$actual_history"
  printf 'Manual check: detach and reattach clients, then confirm modified keys.\n'
  [[ $mode != native-terminal ]] || printf 'Manual check: detach and reattach, then confirm native terminal scrollback.\n'
  exit 0
fi

temp=$(mktemp -d "${TMPDIR:-/tmp}/basix-tmux-verify.XXXXXX") || fail "cannot create isolated workspace"
cleanup() {
  for socket in verify-mouse-$$ verify-native-$$ verify-keyboard-$$; do
    TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" kill-server >/dev/null 2>&1 || true
  done
  rm -rf -- "$temp"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$temp/home" "$temp/socket"

for mode in tmux-mouse native-terminal keyboard-only; do
  case $mode in tmux-mouse) socket=verify-mouse-$$ ;; native-terminal) socket=verify-native-$$ ;; *) socket=verify-keyboard-$$ ;; esac
  HOME=$temp/home XDG_CONFIG_HOME='' TMUX='' TMUX_TMPDIR=$temp/socket "$configure" --mode "$mode" --target-home "$temp/home" --apply >/dev/null
  entry=$temp/home/.config/tmux/tmux.conf
  TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" -f /dev/null new-session -d
  before_root_keys=$(TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" list-keys -T root Up 2>/dev/null || true)
  before_root_keys+=$(TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" list-keys -T root Down 2>/dev/null || true)
  before_root_keys+=$(TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" list-keys -T root WheelUpPane 2>/dev/null || true)
  before_root_keys+=$(TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" list-keys -T root WheelDownPane 2>/dev/null || true)
  TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" source-file "$entry"
  after_root_keys=$(TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" list-keys -T root Up 2>/dev/null || true)
  after_root_keys+=$(TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" list-keys -T root Down 2>/dev/null || true)
  after_root_keys+=$(TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" list-keys -T root WheelUpPane 2>/dev/null || true)
  after_root_keys+=$(TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" list-keys -T root WheelDownPane 2>/dev/null || true)
  [[ $after_root_keys == "$before_root_keys" ]] || fail "$mode changed an Up, Down, or wheel root binding"
  actual_mouse=$(TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" show-options -gv mouse)
  actual_history=$(TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" show-options -gv history-limit)
  actual_extended_keys=$(TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" show-options -sv extended-keys)
  actual_extkeys_feature=$(TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" show-options -sv 'terminal-features[1000]')
  [[ $actual_history == 50000 ]] || fail "$mode isolated history-limit mismatch"
  [[ $actual_extended_keys == on ]] || fail "$mode isolated extended-keys mismatch"
  [[ $actual_extkeys_feature == 'xterm*:extkeys' ]] || fail "$mode isolated terminal feature mismatch"
  if [[ $mode == tmux-mouse ]]; then [[ $actual_mouse == on ]] || fail "tmux-mouse isolated mouse mismatch"
  else [[ $actual_mouse == off ]] || fail "$mode isolated mouse mismatch"; fi
  if [[ $mode == native-terminal ]]; then
    [[ $(TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" show-options -gv 'terminal-overrides[1000]') == 'xterm*:smcup@:rmcup@' ]] || fail "native-terminal isolated override mismatch"
  fi
  if grep -Eq 'bind-key([^#]*(^|[[:space:]]))(Up|Down|C-c|C-Enter|C-j|S-Enter)([[:space:]]|$)' "$temp/home/.config/tmux/conf.d/basix-terminal.conf"; then fail "$mode creates a forbidden physical or modified-key root binding"; fi
  TMUX='' TMUX_TMPDIR=$temp/socket tmux -L "$socket" kill-server >/dev/null
done
printf 'Isolated tmux verification passed for all three modes.\n'

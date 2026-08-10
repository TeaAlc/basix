#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: configure-tmux.sh --mode MODE [OPTIONS]

Modes: tmux-mouse, native-terminal, keyboard-only
Options:
  --history-limit NUMBER
  --clipboard-helper disabled|auto|wl-paste|xclip|xsel
  --target-home PATH
  --entry-config PATH
  --socket-name NAME | --socket-path PATH
  --apply                 Write files (default: dry-run)
  --reload                Source only the managed fragment after apply
EOF
}

fail() { printf 'configure-tmux: %s\n' "$1" >&2; exit "${2:-2}"; }
quote_tmux_double() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}
backup_file() {
  local path=$1 stamp backup
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  backup=${path}.basix-backup.${stamp}.$$
  cp -p -- "$path" "$backup" || fail "cannot back up $path"
  printf 'Backup: %s\n' "$backup"
}
file_mode() { stat -c '%a' -- "$1" 2>/dev/null || printf '600'; }
install_atomic() {
  local generated=$1 destination=$2 default_mode=$3 mode temp
  mkdir -p -- "${destination%/*}" || fail "cannot create ${destination%/*}"
  if [[ -e $destination ]]; then
    mode=$(file_mode "$destination")
    backup_file "$destination"
  else
    mode=$default_mode
  fi
  temp=$(mktemp "${destination%/*}/.basix-tmux.XXXXXX") || fail "cannot create temporary file beside $destination"
  cp -- "$generated" "$temp" || { rm -f -- "$temp"; fail "cannot stage $destination"; }
  chmod "$mode" "$temp" || { rm -f -- "$temp"; fail "cannot preserve permissions for $destination"; }
  mv -f -- "$temp" "$destination" || { rm -f -- "$temp"; fail "cannot replace $destination"; }
}
show_diff() {
  local old=$1 new=$2 label=$3
  if [[ -e $old ]]; then
    diff -U0 --label "a/$label" --label "b/$label" -- "$old" "$new" || [[ $? == 1 ]]
  else
    diff -U0 --label /dev/null --label "b/$label" -- /dev/null "$new" || [[ $? == 1 ]]
  fi
}

mode=
history_limit=50000
clipboard_helper=disabled
target_home=
entry_config=
entry_was_explicit=false
socket_name=
socket_path=
apply=false
reload=false
while (( $# )); do
  case $1 in
    --mode|--history-limit|--clipboard-helper|--target-home|--entry-config|--socket-name|--socket-path)
      (( $# >= 2 )) || fail "missing value for $1" 64
      case $1 in
        --mode) mode=$2 ;;
        --history-limit) history_limit=$2 ;;
        --clipboard-helper) clipboard_helper=$2 ;;
        --target-home) target_home=$2 ;;
        --entry-config) entry_config=$2; entry_was_explicit=true ;;
        --socket-name) socket_name=$2 ;;
        --socket-path) socket_path=$2 ;;
      esac
      shift 2
      ;;
    --apply) apply=true; shift ;;
    --reload) reload=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" 64 ;;
  esac
done

case $mode in tmux-mouse|native-terminal|keyboard-only) ;; *) fail "--mode is required and must name a supported mode" 64 ;; esac
[[ $history_limit =~ ^[1-9][0-9]*$ ]] || fail "--history-limit must be a positive integer" 64
case $clipboard_helper in disabled|auto|wl-paste|xclip|xsel) ;; *) fail "invalid --clipboard-helper" 64 ;; esac
[[ $mode == tmux-mouse || $clipboard_helper == disabled ]] || fail "clipboard helper is available only in tmux-mouse mode" 64
[[ -z $socket_name || -z $socket_path ]] || fail "--socket-name and --socket-path are mutually exclusive" 64
$reload && ! $apply && fail "--reload requires --apply" 64

if [[ -z $target_home ]]; then
  [[ -n ${HOME:-} ]] || fail "HOME is unset; use --target-home"
  target_home=$HOME
fi
[[ $target_home == /* && $target_home != / ]] || fail "target home must be an absolute non-root path"
[[ -d $target_home ]] || fail "target home is not a directory: $target_home"
case $target_home in *$'\n'*|*$'\r'*) fail "target home contains an unsupported newline" ;; esac

if [[ -z ${XDG_CONFIG_HOME:-} || $target_home != "${HOME:-}" ]]; then
  config_home=$target_home/.config
else
  [[ $XDG_CONFIG_HOME == /* ]] || fail "XDG_CONFIG_HOME must be absolute"
  config_home=$XDG_CONFIG_HOME
fi
case $config_home in *$'\n'*|*$'\r'*|*$'\t'*) fail "config home contains unsupported control characters" ;; esac
managed_dir=$config_home/tmux
fragment=$managed_dir/conf.d/basix-terminal.conf
helper_destination=$managed_dir/bin/basix-clipboard-paste
helper_source=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tmux-clipboard-paste.sh
if [[ $clipboard_helper != disabled ]]; then
  [[ $helper_destination != *"'"* && $helper_destination != *'"'* && $helper_destination != *'\'* && $helper_destination != *'$'* && $helper_destination != *'`'* ]] || \
    fail "clipboard helper path contains shell-sensitive characters"
fi
for directory in "$config_home" "$managed_dir" "$managed_dir/conf.d" "$managed_dir/bin"; do
  [[ ! -L $directory ]] || fail "refusing a symlinked managed directory: $directory"
  [[ ! -e $directory || -d $directory ]] || fail "managed directory path is not a directory: $directory"
done

legacy_entry=$target_home/.tmux.conf
xdg_entry=$managed_dir/tmux.conf
if [[ -z $entry_config ]]; then
  if [[ -e $legacy_entry && -e $xdg_entry ]]; then
    fail "both $legacy_entry and $xdg_entry exist; select one with --entry-config"
  elif [[ -e $legacy_entry ]]; then
    entry_config=$legacy_entry
  else
    entry_config=$xdg_entry
  fi
fi
[[ $entry_config == /* ]] || fail "entry config must be an absolute path"

for path in "$entry_config" "$fragment" "$helper_destination"; do
  [[ ! -L $path ]] || fail "refusing to modify symlink: $path"
  [[ ! -e $path || -f $path ]] || fail "refusing non-regular file: $path"
done
[[ -r $helper_source ]] || fail "bundled clipboard helper is missing"

begin_marker='# >>> basix configure-tmux >>>'
end_marker='# <<< basix configure-tmux <<<'
source_path=$(quote_tmux_double "$fragment")
source_directive="source-file \"$source_path\""
begin_count=0
end_count=0
if [[ -e $entry_config ]]; then
  begin_count=$(grep -Fxc "$begin_marker" "$entry_config" || true)
  end_count=$(grep -Fxc "$end_marker" "$entry_config" || true)
fi
(( begin_count == end_count && begin_count <= 1 )) || fail "entry config contains incomplete or duplicate Basix markers"
if [[ -e $entry_config && $begin_count == 1 ]]; then
  marker_inside=false
  marker_seen=false
  managed_lines=()
  while IFS= read -r marker_line || [[ -n $marker_line ]]; do
    if [[ $marker_line == "$begin_marker" ]]; then
      ! $marker_inside && ! $marker_seen || fail "Basix source block contains foreign content or invalid ordering"
      marker_inside=true; marker_seen=true; continue
    fi
    if [[ $marker_line == "$end_marker" ]]; then
      $marker_inside || fail "Basix source block contains foreign content or invalid ordering"
      marker_inside=false; continue
    fi
    $marker_inside && managed_lines+=("$marker_line")
  done <"$entry_config"
  ! $marker_inside && $marker_seen && [[ ${#managed_lines[@]} == 1 && ${managed_lines[0]} == "$source_directive" ]] || \
    fail "Basix source block contains foreign content or invalid ordering"
fi

old_mode=
old_binding=none
old_schema=
old_extkeys_owned=false
if [[ -e $fragment ]]; then
  mapfile -t fragment_lines <"$fragment"
  case ${fragment_lines[0]:-} in
    '# Basix configure-tmux schema=1') old_schema=1; mode_line=4 ;;
    '# Basix configure-tmux schema=2') old_schema=2; mode_line=6; old_extkeys_owned=true ;;
    *) fail "managed fragment contains foreign or unsupported content" ;;
  esac
  old_mode=$(sed -n 's/^# mode=//p' "$fragment" | head -n1)
  old_binding=$(sed -n 's/^# managed-bindings=//p' "$fragment" | head -n1)
  case $old_mode in tmux-mouse|native-terminal|keyboard-only) ;; *) fail "managed fragment has invalid mode metadata" ;; esac
  case $old_binding in none|MouseDown3Pane) ;; *) fail "managed fragment has invalid binding metadata" ;; esac
  [[ ${fragment_lines[1]:-} == "# mode=$old_mode" && ${fragment_lines[2]:-} == "# managed-bindings=$old_binding" ]] || fail "managed fragment metadata is duplicated or out of order"
  [[ ${fragment_lines[3]:-} =~ ^set-option\ -g\ history-limit\ [1-9][0-9]*$ ]] || fail "managed fragment has a foreign history definition"
  if [[ $old_schema == 2 ]]; then
    [[ ${fragment_lines[5]:-} == 'set-option -s extended-keys on' ]] || fail "managed fragment has a foreign extended-keys definition"
    [[ ${fragment_lines[6]:-} == "set-option -s 'terminal-features[1000]' 'xterm*:extkeys'" ]] || fail "managed fragment has a foreign terminal feature"
  fi
  if [[ $old_mode == tmux-mouse ]]; then
    [[ ${fragment_lines[4]:-} == 'set-option -g mouse on' ]] || fail "managed fragment has a foreign mouse definition"
    if [[ $old_binding == none ]]; then
      [[ ${#fragment_lines[@]} == $((mode_line + 1)) ]] || fail "managed fragment contains foreign trailing content"
    else
      [[ ${#fragment_lines[@]} == $((mode_line + 2)) ]] || fail "managed fragment contains foreign binding content"
      old_binding_valid=false
      helper_quoted=$(quote_tmux_double "$helper_destination")
      for candidate in auto wl-paste xclip xsel; do
        expected="bind-key -n MouseDown3Pane run-shell -b '\"$helper_quoted\" \"#{pane_id}\" \"$candidate\"'"
        if [[ ${fragment_lines[mode_line + 1]} == "$expected" ]]; then old_binding_valid=true; break; fi
      done
      $old_binding_valid || fail "managed fragment contains a foreign MouseDown3Pane definition"
    fi
  elif [[ $old_mode == native-terminal ]]; then
    [[ $old_binding == none && ${#fragment_lines[@]} == $((mode_line + 2)) ]] || fail "native fragment contains foreign binding or trailing content"
    [[ ${fragment_lines[4]:-} == 'set-option -g mouse off' && ${fragment_lines[mode_line + 1]:-} == "set-option -g 'terminal-overrides[1000]' 'xterm*:smcup@:rmcup@'" ]] || fail "native fragment contains a foreign terminal override"
  else
    [[ $old_binding == none && ${#fragment_lines[@]} == $((mode_line + 1)) && ${fragment_lines[4]:-} == 'set-option -g mouse off' ]] || fail "keyboard fragment contains foreign content"
  fi
fi

if [[ -e $entry_config ]]; then
  outside_index=$(awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { managed=1; next }
    $0 == end { managed=0; next }
    !managed && /(terminal-overrides|terminal-features)\[1000\]/ { print; exit }
  ' "$entry_config")
  [[ -z $outside_index ]] || fail "entry config uses a Basix-reserved array index outside the Basix block"
fi

tmux_bin=${TMUX_BIN:-tmux}
managed_binding=none
[[ $mode == tmux-mouse && $clipboard_helper != disabled ]] && managed_binding=MouseDown3Pane
probe_binding_definition() {
  local config=$1 temp socket definition
  temp=$(mktemp -d "${TMPDIR:-/tmp}/basix-tmux-binding-probe.XXXXXX") || fail "cannot create tmux binding probe directory"
  socket=basix-binding-probe-$$
  if ! TMUX='' TMUX_TMPDIR=$temp "$tmux_bin" -L "$socket" -f "$config" new-session -d 2>/dev/null; then
    rm -rf -- "$temp"
    fail "cannot start isolated tmux binding probe"
  fi
  definition=$(TMUX='' TMUX_TMPDIR=$temp "$tmux_bin" -L "$socket" list-keys -T root MouseDown3Pane 2>/dev/null || true)
  TMUX='' TMUX_TMPDIR=$temp "$tmux_bin" -L "$socket" kill-server >/dev/null 2>&1 || true
  rm -rf -- "$temp"
  [[ -n $definition ]] || fail "isolated tmux did not load the previous Basix mouse binding"
  printf '%s\n' "$definition"
}
expected_old_live_binding=
if $reload && [[ $old_binding == MouseDown3Pane ]]; then
  command -v "$tmux_bin" >/dev/null 2>&1 || fail "tmux is required to validate the previous live binding"
  expected_old_live_binding=$(probe_binding_definition "$fragment")
fi
server_args=()
if [[ -n $socket_name ]]; then server_args=(-L "$socket_name")
elif [[ -n $socket_path ]]; then server_args=(-S "$socket_path"); fi
live_reachable=false
if $reload && [[ -z $socket_name && -z $socket_path && -z ${TMUX:-} ]]; then
  fail "--reload requires --socket-name, --socket-path, or an active TMUX environment"
fi
if command -v "$tmux_bin" >/dev/null 2>&1 && { [[ -n $socket_name || -n $socket_path || -n ${TMUX:-} ]]; }; then
  if "$tmux_bin" "${server_args[@]}" list-clients >/dev/null 2>&1; then
    live_reachable=true
    live_configs=$($tmux_bin "${server_args[@]}" display-message -p '#{config_files}' 2>/dev/null || true)
    if [[ -n $live_configs && $live_configs != *"$entry_config"* ]] && ! $entry_was_explicit; then
      fail "selected server reports a different config; rerun with its exact --entry-config"
    fi
    if [[ $mode == native-terminal || $old_mode == native-terminal ]]; then
      live_index=$($tmux_bin "${server_args[@]}" show-options -gv 'terminal-overrides[1000]' 2>/dev/null || true)
      if [[ -n $live_index && $old_mode != native-terminal ]]; then
        fail "live terminal-overrides[1000] is not known to be Basix-owned"
      fi
      if [[ $old_mode == native-terminal && -n $live_index && $live_index != 'xterm*:smcup@:rmcup@' ]]; then
        fail "live terminal-overrides[1000] no longer matches the Basix definition"
      fi
    fi
    live_features=$($tmux_bin "${server_args[@]}" show-options -sv 'terminal-features[1000]' 2>/dev/null || true)
    if [[ -n $live_features && $old_extkeys_owned != true ]]; then
      fail "live terminal-features[1000] is not known to be Basix-owned"
    fi
    if $old_extkeys_owned && [[ -n $live_features && $live_features != 'xterm*:extkeys' ]]; then
      fail "live terminal-features[1000] no longer matches the Basix definition"
    fi
    if $reload; then
      preflight_binding=$($tmux_bin "${server_args[@]}" list-keys -T root MouseDown3Pane 2>/dev/null || true)
      if [[ $managed_binding == MouseDown3Pane && -n $preflight_binding && $old_binding != MouseDown3Pane ]]; then
        fail "live MouseDown3Pane binding is not known to be Basix-owned"
      fi
      if [[ $old_binding == MouseDown3Pane && -n $preflight_binding && $preflight_binding != "$expected_old_live_binding" ]]; then
        fail "live MouseDown3Pane no longer matches the Basix definition"
      fi
    fi
  fi
fi
$reload && ! $live_reachable && fail "selected tmux server is not reachable; no files were changed" 1
probe_extended_keys_syntax() {
  command -v "$tmux_bin" >/dev/null 2>&1 || fail "tmux is required to validate extended-keys support"
  local temp socket
  temp=$(mktemp -d "${TMPDIR:-/tmp}/basix-tmux-probe.XXXXXX") || fail "cannot create tmux probe directory"
  socket=basix-probe-$$
  if ! TMUX='' TMUX_TMPDIR=$temp "$tmux_bin" -L "$socket" -f /dev/null new-session -d 2>/dev/null; then
    rm -rf -- "$temp"
    fail "cannot start isolated tmux syntax probe"
  fi
  if ! TMUX='' TMUX_TMPDIR=$temp "$tmux_bin" -L "$socket" set-option -s extended-keys on 2>/dev/null; then
    TMUX='' TMUX_TMPDIR=$temp "$tmux_bin" -L "$socket" kill-server >/dev/null 2>&1 || true
    rm -rf -- "$temp"
    fail "this tmux does not support extended-keys"
  fi
  if ! TMUX='' TMUX_TMPDIR=$temp "$tmux_bin" -L "$socket" set-option -s 'terminal-features[1000]' 'xterm*:extkeys' 2>/dev/null; then
    TMUX='' TMUX_TMPDIR=$temp "$tmux_bin" -L "$socket" kill-server >/dev/null 2>&1 || true
    rm -rf -- "$temp"
    fail "this tmux does not support terminal-features array index 1000"
  fi
  if [[ $mode == native-terminal || $old_mode == native-terminal ]] && \
     ! TMUX='' TMUX_TMPDIR=$temp "$tmux_bin" -L "$socket" set-option -g 'terminal-overrides[1000]' 'xterm*:smcup@:rmcup@' 2>/dev/null; then
    TMUX='' TMUX_TMPDIR=$temp "$tmux_bin" -L "$socket" kill-server >/dev/null 2>&1 || true
    rm -rf -- "$temp"
    fail "this tmux does not support terminal-overrides array index 1000"
  fi
  TMUX='' TMUX_TMPDIR=$temp "$tmux_bin" -L "$socket" kill-server >/dev/null 2>&1 || true
  rm -rf -- "$temp"
}
probe_extended_keys_syntax

if [[ $clipboard_helper != disabled ]]; then
  case $clipboard_helper in
    auto)
      if [[ -n ${WAYLAND_DISPLAY:-} ]] && command -v wl-paste >/dev/null 2>&1; then :
      elif [[ -n ${DISPLAY:-} ]] && { command -v xclip >/dev/null 2>&1 || command -v xsel >/dev/null 2>&1; }; then :
      else fail "auto clipboard helper has no usable display transport"; fi
      ;;
    wl-paste) [[ -n ${WAYLAND_DISPLAY:-} ]] && command -v wl-paste >/dev/null 2>&1 || fail "wl-paste requires WAYLAND_DISPLAY and wl-paste" ;;
    xclip|xsel) [[ -n ${DISPLAY:-} ]] && command -v "$clipboard_helper" >/dev/null 2>&1 || fail "$clipboard_helper requires DISPLAY and $clipboard_helper" ;;
  esac
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/basix-tmux-configure.XXXXXX") || fail "cannot create temporary workspace"
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
generated_fragment=$work/fragment
generated_entry=$work/entry

{
  printf '%s\n' '# Basix configure-tmux schema=2'
  printf '# mode=%s\n' "$mode"
  printf '# managed-bindings=%s\n' "$managed_binding"
  printf 'set-option -g history-limit %s\n' "$history_limit"
  if [[ $mode == tmux-mouse ]]; then
    printf '%s\n' 'set-option -g mouse on'
  else
    printf '%s\n' 'set-option -g mouse off'
  fi
  printf '%s\n' 'set-option -s extended-keys on'
  printf "%s\n" "set-option -s 'terminal-features[1000]' 'xterm*:extkeys'"
  if [[ $mode == native-terminal ]]; then
    printf "%s\n" "set-option -g 'terminal-overrides[1000]' 'xterm*:smcup@:rmcup@'"
  fi
  if [[ $managed_binding == MouseDown3Pane ]]; then
    helper_quoted=$(quote_tmux_double "$helper_destination")
    printf "bind-key -n MouseDown3Pane run-shell -b '\"%s\" \"#{pane_id}\" \"%s\"'\n" "$helper_quoted" "$clipboard_helper"
  fi
} >"$generated_fragment"

if [[ -e $entry_config && $begin_count == 0 ]]; then
  cp -- "$entry_config" "$generated_entry"
  [[ ! -s $generated_entry ]] || printf '\n' >>"$generated_entry"
  printf '%s\nsource-file "%s"\n%s\n' "$begin_marker" "$source_path" "$end_marker" >>"$generated_entry"
elif [[ -e $entry_config ]]; then
  marker_inside=false
  while IFS= read -r marker_line || [[ -n $marker_line ]]; do
    if [[ $marker_line == "$begin_marker" ]]; then
      printf '%s\n%s\n' "$begin_marker" "$source_directive"
      marker_inside=true
    elif [[ $marker_line == "$end_marker" ]]; then
      printf '%s\n' "$end_marker"
      marker_inside=false
    elif ! $marker_inside; then
      printf '%s\n' "$marker_line"
    fi
  done <"$entry_config" >"$generated_entry"
else
  printf '%s\nsource-file "%s"\n%s\n' "$begin_marker" "$source_path" "$end_marker" >"$generated_entry"
fi

printf 'Mode: %s\n' "$mode"
printf 'Entry config: %s\nManaged fragment: %s\n' "$entry_config" "$fragment"
changed=false
if [[ ! -e $entry_config ]] || ! cmp -s -- "$entry_config" "$generated_entry"; then
  changed=true
  show_diff "$entry_config" "$generated_entry" entry-config
fi
if [[ ! -e $fragment ]] || ! cmp -s -- "$fragment" "$generated_fragment"; then
  changed=true
  show_diff "$fragment" "$generated_fragment" managed-fragment
fi
if [[ ! -e $helper_destination ]] || ! cmp -s -- "$helper_source" "$helper_destination"; then
  if [[ -e $helper_destination ]]; then
    fail "installed clipboard helper differs from the Basix-managed helper"
  fi
  changed=true
  printf 'Would install executable helper: %s\n' "$helper_destination"
fi
if $reload; then
  printf 'Planned live action: source only %s\n' "$fragment"
  [[ $old_mode != native-terminal || $mode == native-terminal ]] || printf 'Planned live action: remove Basix-owned terminal-overrides[1000]\n'
  [[ $old_binding != MouseDown3Pane || $managed_binding == MouseDown3Pane ]] || printf 'Planned live action: remove Basix-owned MouseDown3Pane binding\n'
fi
if ! $apply; then
  $changed || printf 'No file changes.\n'
  printf 'Dry-run only; rerun with --apply after explicit confirmation.\n'
  exit 0
fi

if [[ ! -e $entry_config ]] || ! cmp -s -- "$entry_config" "$generated_entry"; then install_atomic "$generated_entry" "$entry_config" 600; fi
if [[ ! -e $fragment ]] || ! cmp -s -- "$fragment" "$generated_fragment"; then install_atomic "$generated_fragment" "$fragment" 600; fi
if [[ ! -e $helper_destination ]]; then install_atomic "$helper_source" "$helper_destination" 755; fi

if $reload; then
  live_index=$($tmux_bin "${server_args[@]}" show-options -gv 'terminal-overrides[1000]' 2>/dev/null || true)
  live_features=$($tmux_bin "${server_args[@]}" show-options -sv 'terminal-features[1000]' 2>/dev/null || true)
  live_binding=$($tmux_bin "${server_args[@]}" list-keys -T root MouseDown3Pane 2>/dev/null || true)
  if [[ -n $live_features && $old_extkeys_owned != true ]]; then
    fail "live terminal-features[1000] is not known to be Basix-owned; files were applied but not reloaded"
  fi
  if $old_extkeys_owned && [[ -n $live_features && $live_features != 'xterm*:extkeys' ]]; then
    fail "live terminal-features[1000] no longer matches the Basix definition; files were applied but not reloaded"
  fi
  if [[ $managed_binding == MouseDown3Pane && -n $live_binding && $old_binding != MouseDown3Pane ]]; then
    fail "live MouseDown3Pane binding is not known to be Basix-owned; files were applied but not reloaded"
  fi
  if [[ $old_binding == MouseDown3Pane && -n $live_binding ]]; then
    [[ $live_binding == "$expected_old_live_binding" ]] || \
    fail "live MouseDown3Pane no longer matches the Basix definition; files were applied but not reloaded"
  fi
  "$tmux_bin" "${server_args[@]}" source-file "$fragment" || fail "tmux rejected the managed fragment; files remain applied"
  if [[ $old_mode == native-terminal && $mode != native-terminal ]]; then
    "$tmux_bin" "${server_args[@]}" set-option -gu 'terminal-overrides[1000]' || fail "could not remove the old Basix terminal override"
  fi
  if [[ $old_binding == MouseDown3Pane && $managed_binding != MouseDown3Pane ]]; then
    "$tmux_bin" "${server_args[@]}" unbind-key -n MouseDown3Pane || fail "could not remove the old Basix mouse binding"
  fi
  printf 'Note: detach and reattach clients so extended-key terminal capabilities are renegotiated.\n'
  [[ $old_mode != native-terminal && $mode != native-terminal ]] || printf 'Note: detach and reattach clients for alternate-screen capability changes.\n'
fi
printf 'Configuration applied successfully.\n'

#!/usr/bin/env bash
set -u

usage() {
  cat <<'EOF'
Usage: diagnose-tmux.sh [--format text|json] [--target-home PATH]
                        [--entry-config PATH]
                        [--socket-name NAME | --socket-path PATH]
EOF
}
fail() { printf 'diagnose-tmux: %s\n' "$1" >&2; exit "${2:-2}"; }
json_string() {
  local value=$1 character ordinal i
  local LC_ALL=C
  printf '"'
  for (( i=0; i<${#value}; i++ )); do
    character=${value:i:1}
    case $character in
      '"') printf '\\"' ;;
      '\') printf '\\\\' ;;
      $'\b') printf '\\b' ;;
      $'\f') printf '\\f' ;;
      $'\n') printf '\\n' ;;
      $'\r') printf '\\r' ;;
      $'\t') printf '\\t' ;;
      *)
        printf -v ordinal '%d' "'$character"
        if (( ordinal < 32 || ordinal == 127 )); then printf '\\u%04x' "$ordinal"; else printf '%s' "$character"; fi
        ;;
    esac
  done
  printf '"'
}
add_check() {
  check_ids+=("$1"); check_statuses+=("$2"); check_summaries+=("$3")
  case $2 in error) overall=error ;; warning) [[ $overall == error ]] || overall=warning ;; esac
}

format=text
target_home=
entry_config=
socket_name=
socket_path=
while (( $# )); do
  case $1 in
    --format|--target-home|--entry-config|--socket-name|--socket-path)
      (( $# >= 2 )) || fail "missing value for $1" 64
      case $1 in
        --format) format=$2 ;;
        --target-home) target_home=$2 ;;
        --entry-config) entry_config=$2 ;;
        --socket-name) socket_name=$2 ;;
        --socket-path) socket_path=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" 64 ;;
  esac
done
case $format in text|json) ;; *) fail "--format must be text or json" 64 ;; esac
[[ -z $socket_name || -z $socket_path ]] || fail "--socket-name and --socket-path are mutually exclusive" 64
if [[ -z $target_home ]]; then
  [[ -n ${HOME:-} ]] || fail "HOME is unset; use --target-home"
  target_home=$HOME
fi
[[ $target_home == /* && $target_home != / ]] || fail "target home must be an absolute non-root path"

if [[ -z ${XDG_CONFIG_HOME:-} || $target_home != "${HOME:-}" ]]; then config_home=$target_home/.config; else config_home=$XDG_CONFIG_HOME; fi
legacy_entry=$target_home/.tmux.conf
xdg_entry=$config_home/tmux/tmux.conf

overall=ok
check_ids=(); check_statuses=(); check_summaries=()
tmux_version=unavailable
server_reachable=false
client_present=false
mouse=unknown
history_limit=unknown
alternate_screen=unknown
pane_in_mode=unknown
config_loaded=unknown
root_binding_state=unknown
extended_keys=unknown
client_extkeys_status=missing
client_extkeys=()
possible_root_bindings=()
term=${TERM:-unknown}

if command -v tmux >/dev/null 2>&1; then
  tmux_version=$(tmux -V 2>/dev/null || printf 'unknown')
  add_check tmux ok "$tmux_version is available"
else
  add_check tmux warning "tmux is not installed; runtime checks are limited"
fi

if [[ -n $entry_config ]]; then
  if [[ -L $entry_config ]]; then add_check config warning "explicit entry config is a symlink and requires manual review"
  elif [[ -f $entry_config ]]; then add_check config ok "explicit entry config is readable"
  elif [[ -e $entry_config ]]; then add_check config error "explicit entry config is not a regular file"
  else add_check config warning "explicit entry config does not exist"; fi
elif [[ -e $legacy_entry && -e $xdg_entry ]]; then
  add_check config warning "both standard entry configs exist; select the active one explicitly"
elif [[ -L $legacy_entry ]]; then entry_config=$legacy_entry; add_check config warning "legacy entry config is a symlink and requires manual review"
elif [[ -f $legacy_entry ]]; then entry_config=$legacy_entry; add_check config ok "legacy entry config found"
elif [[ -L $xdg_entry ]]; then entry_config=$xdg_entry; add_check config warning "XDG entry config is a symlink and requires manual review"
elif [[ -f $xdg_entry ]]; then entry_config=$xdg_entry; add_check config ok "XDG entry config found"
else entry_config=$xdg_entry; add_check config warning "no standard entry config exists"
fi

server_args=()
socket_kind=default
socket_value=default
if [[ -n $socket_name ]]; then server_args=(-L "$socket_name"); socket_kind=name; socket_value=$socket_name
elif [[ -n $socket_path ]]; then server_args=(-S "$socket_path"); socket_kind=path; socket_value=$socket_path
elif [[ -n ${TMUX:-} ]]; then socket_kind=environment; socket_value=active
fi

if command -v tmux >/dev/null 2>&1; then
  if tmux "${server_args[@]}" list-clients >/dev/null 2>&1; then
    server_reachable=true
    add_check server ok "selected tmux server is reachable"
    client_lines=$(tmux "${server_args[@]}" list-clients -F '#{client_tty}' 2>/dev/null || true)
    [[ -n $client_lines ]] && client_present=true
    if $client_present; then add_check client ok "at least one tmux client is attached"; else add_check client warning "server has no attached client"; fi
    mouse=$(tmux "${server_args[@]}" show-options -gv mouse 2>/dev/null || printf unknown)
    history_limit=$(tmux "${server_args[@]}" show-options -gv history-limit 2>/dev/null || printf unknown)
    extended_keys=$(tmux "${server_args[@]}" show-options -sv extended-keys 2>/dev/null || printf unknown)
    [[ $mouse == on ]] && add_check mouse ok "tmux mouse mode is enabled" || add_check mouse warning "tmux mouse mode is not enabled"
    [[ $extended_keys == on ]] && add_check extended_keys ok "tmux extended-keys transport is enabled without rewriting legacy control keys" || add_check extended_keys warning "tmux extended-keys transport is not safely enabled"
    mapfile -t client_feature_lines < <(tmux "${server_args[@]}" list-clients -F '#{client_tty}|#{client_termfeatures}' 2>/dev/null || true)
    enabled_clients=0
    disabled_clients=0
    for client_feature_line in "${client_feature_lines[@]}"; do
      [[ -n $client_feature_line ]] || continue
      client_tty=${client_feature_line%%|*}
      client_features=${client_feature_line#*|}
      if [[ ,$client_features, == *,extkeys,* ]]; then
        client_extkeys+=("$client_tty:enabled")
        (( enabled_clients++ ))
      else
        client_extkeys+=("$client_tty:disabled")
        (( disabled_clients++ ))
      fi
    done
    if (( enabled_clients && disabled_clients )); then
      client_extkeys_status=mixed
      add_check client_extkeys warning "attached clients have mixed effective extkeys support"
    elif (( enabled_clients )); then
      client_extkeys_status=enabled
      add_check client_extkeys ok "all attached clients have effective extkeys support"
    elif (( disabled_clients )); then
      client_extkeys_status=disabled
      add_check client_extkeys warning "attached clients lack effective extkeys support"
    else
      client_extkeys_status=missing
      add_check client_extkeys warning "effective client extkeys support could not be inspected"
    fi
    pane_state=$(tmux "${server_args[@]}" list-panes -a -F '#{alternate_on} #{pane_in_mode}' 2>/dev/null | head -n1 || true)
    if [[ -n $pane_state ]]; then
      alternate_screen=${pane_state%% *}; pane_in_mode=${pane_state#* }
      [[ $pane_in_mode == 0 ]] && add_check foreground ok "sample pane is not in a tmux mode" || add_check foreground warning "sample pane is in copy/view mode or an application-controlled mode"
      [[ $alternate_screen == 0 ]] && add_check alternate_screen ok "sample pane is on the primary screen" || add_check alternate_screen warning "sample pane uses the alternate screen; terminal scrollback may be hidden"
    else
      add_check foreground warning "pane state could not be inspected"
    fi
    loaded_configs=$(tmux "${server_args[@]}" display-message -p '#{config_files}' 2>/dev/null || true)
    if [[ -n $entry_config && -n $loaded_configs && $loaded_configs == *"$entry_config"* ]]; then config_loaded=true; add_check config_loaded ok "selected entry config appears in the live server"
    elif [[ -n $loaded_configs ]]; then config_loaded=false; add_check config_loaded warning "selected entry config is not reported by the live server"
    else add_check config_loaded warning "tmux does not expose loaded config paths"
    fi
    root_bindings=$(tmux "${server_args[@]}" list-keys -T root 2>/dev/null | awk '$4 ~ /^(WheelUpPane|WheelDownPane|MouseDown3Pane|Up|Down|C-c|C-Enter|C-j|S-Enter)$/ {print}' || true)
    mapfile -t possible_root_bindings < <(printf '%s\n' "$root_bindings" | awk '$4 ~ /^(C-c|C-Enter|C-j|S-Enter)$/ {print}')
    if [[ -n $root_bindings ]]; then root_binding_state=present; add_check root_bindings warning "relevant root bindings exist; compare them before changing mouse behavior"
    else root_binding_state=none; add_check root_bindings ok "no relevant root binding conflict was found"; fi
  else
    if [[ $socket_kind == default ]]; then add_check server warning "no default tmux server is reachable"
    else add_check server warning "selected tmux socket is unreachable or belongs to another user"; fi
  fi
fi

kmous=false; smcup=false; rmcup=false
if command -v infocmp >/dev/null 2>&1 && [[ $term != unknown ]]; then
  terminfo=$(infocmp -1 "$term" 2>/dev/null || true)
  grep -Eq '^[[:space:]]*kmous=' <<<"$terminfo" && kmous=true
  grep -Eq '^[[:space:]]*smcup=' <<<"$terminfo" && smcup=true
  grep -Eq '^[[:space:]]*rmcup=' <<<"$terminfo" && rmcup=true
  $kmous && add_check terminfo_mouse ok "terminfo includes kmous" || add_check terminfo_mouse warning "terminfo does not expose kmous"
  if $smcup && $rmcup; then add_check terminfo_screen ok "terminfo includes smcup and rmcup"; else add_check terminfo_screen warning "terminfo lacks smcup or rmcup"; fi
else
  add_check terminfo warning "terminfo could not be inspected"
fi

clipboard_transports=()
if [[ -n ${WAYLAND_DISPLAY:-} ]] && command -v wl-paste >/dev/null 2>&1; then clipboard_transports+=(wl-paste); fi
if [[ -n ${DISPLAY:-} ]] && command -v xclip >/dev/null 2>&1; then clipboard_transports+=(xclip); fi
if [[ -n ${DISPLAY:-} ]] && command -v xsel >/dev/null 2>&1; then clipboard_transports+=(xsel); fi
if (( ${#clipboard_transports[@]} )); then add_check clipboard ok "a display-aware clipboard transport is available"; else add_check clipboard warning "no display-aware clipboard transport is available"; fi

recommended_modes=(keyboard-only)
if $server_reachable && [[ $mouse == on ]] && $kmous; then recommended_modes=(tmux-mouse keyboard-only)
elif $smcup && $rmcup; then recommended_modes=(native-terminal keyboard-only)
fi
manual_checks=("Confirm wheel and selection behavior in the actual client." "Confirm foreground applications release mouse reporting as expected.")
manual_checks+=("Reconnect each tmux client after capability changes, then test Ctrl+Enter and Shift+Enter.")
[[ ${TERMUX_VERSION:-} ]] && manual_checks+=("Test Android touch and long-press behavior manually; it is client-specific.")

if [[ $format == text ]]; then
  printf 'schema_version=1\noverall_status=%s\n' "$overall"
  printf 'tmux_version=%s\nterminal=%s\nsocket=%s:%s\nentry_config=%s\n' "$tmux_version" "$term" "$socket_kind" "$socket_value" "$entry_config"
  printf 'extended_keys=%s\nclient_extkeys_status=%s\n' "$extended_keys" "$client_extkeys_status"
  for item in "${client_extkeys[@]}"; do printf 'client_extkeys=%s\n' "$item"; done
  for item in "${possible_root_bindings[@]}"; do printf 'possible_root_binding=%s\n' "$item"; done
  for (( i=0; i<${#check_ids[@]}; i++ )); do printf 'check.%s=%s: %s\n' "${check_ids[i]}" "${check_statuses[i]}" "${check_summaries[i]}"; done
  printf 'recommended_modes=%s\n' "$(IFS=,; echo "${recommended_modes[*]}")"
  for item in "${manual_checks[@]}"; do printf 'manual_check=%s\n' "$item"; done
else
  printf '{\n  "schema_version": 1,\n  "overall_status": '; json_string "$overall"; printf ',\n'
  printf '  "context": {"tmux_version": '; json_string "$tmux_version"; printf ', "terminal": '; json_string "$term"
  printf ', "socket_kind": '; json_string "$socket_kind"; printf ', "socket_value": '; json_string "$socket_value"
  printf ', "entry_config": '; json_string "$entry_config"; printf ', "inside_tmux": %s, "server_reachable": %s, "client_present": %s, "mouse": ' "$([[ -n ${TMUX:-} ]] && echo true || echo false)" "$server_reachable" "$client_present"; json_string "$mouse"
  printf ', "history_limit": '; json_string "$history_limit"; printf ', "extended_keys": '; json_string "$extended_keys"; printf ', "client_extkeys_status": '; json_string "$client_extkeys_status"; printf ', "alternate_screen": '; json_string "$alternate_screen"; printf ', "pane_in_mode": '; json_string "$pane_in_mode"
  printf ', "config_loaded": '; json_string "$config_loaded"; printf ', "root_binding_state": '; json_string "$root_binding_state"; printf ', "display_present": %s, "wayland_display_present": %s},\n' "$([[ -n ${DISPLAY:-} ]] && echo true || echo false)" "$([[ -n ${WAYLAND_DISPLAY:-} ]] && echo true || echo false)"
  printf '  "features": {"kmous": %s, "smcup": %s, "rmcup": %s},\n' "$kmous" "$smcup" "$rmcup"
  printf '  "client_extkeys": ['; for (( i=0; i<${#client_extkeys[@]}; i++ )); do (( i )) && printf ', '; json_string "${client_extkeys[i]}"; done; printf '],\n'
  printf '  "possible_root_bindings": ['; for (( i=0; i<${#possible_root_bindings[@]}; i++ )); do (( i )) && printf ', '; json_string "${possible_root_bindings[i]}"; done; printf '],\n'
  printf '  "clipboard_transports": ['; for (( i=0; i<${#clipboard_transports[@]}; i++ )); do (( i )) && printf ', '; json_string "${clipboard_transports[i]}"; done; printf '],\n'
  printf '  "checks": ['
  for (( i=0; i<${#check_ids[@]}; i++ )); do (( i )) && printf ','; printf '\n    {"id": '; json_string "${check_ids[i]}"; printf ', "status": '; json_string "${check_statuses[i]}"; printf ', "summary": '; json_string "${check_summaries[i]}"; printf '}'; done
  printf '\n  ],\n  "recommended_modes": ['; for (( i=0; i<${#recommended_modes[@]}; i++ )); do (( i )) && printf ', '; json_string "${recommended_modes[i]}"; done; printf '],\n'
  printf '  "manual_checks": ['; for (( i=0; i<${#manual_checks[@]}; i++ )); do (( i )) && printf ', '; json_string "${manual_checks[i]}"; done; printf ']\n}\n'
fi

case $overall in ok) exit 0 ;; warning) exit 1 ;; error) exit 2 ;; esac

#!/usr/bin/env bash

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }
orange_warning() { printf '\033[38;5;208mwarning: %s\033[0m\n' "$*" >&2; }
require_mode() { [[ $1 == link || $1 == copy ]] || die "invalid mode: $1"; }
require_yes_no() { [[ $2 == yes || $2 == no ]] || die "invalid $1 value: $2 (expected yes or no)"; }
lumen_mcp_installed() {
  local metadata
  command -v codex >/dev/null || return 1
  metadata=$(codex mcp get lumen --json 2>/dev/null) || return 1
  python3 -c '
import json, sys
try:
    value = json.load(sys.stdin)
    valid = (
        value.get("name") == "lumen"
        and value.get("enabled", True) is True
        and value.get("disabled_reason") is None
    )
except (AttributeError, json.JSONDecodeError):
    valid = False
raise SystemExit(0 if valid else 1)
' <<< "$metadata"
}

lumen_launcher() {
  local metadata command
  metadata=$(codex mcp get lumen --json 2>/dev/null) || return 1
  command=$(python3 -c '
import json, os, sys
try:
    value = json.load(sys.stdin)
    transport = value["transport"]
    command = transport["command"]
    valid = (
        value.get("name") == "lumen"
        and value.get("enabled", True) is True
        and transport.get("type") == "stdio"
        and transport.get("args") == ["stdio"]
        and isinstance(command, str)
        and command.endswith("/lumen/scripts/run")
        and os.path.isfile(command)
        and os.access(command, os.X_OK)
    )
    if not valid:
        raise ValueError
    print(command)
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
' <<< "$metadata") || return 1
  printf '%s\n' "$command"
}
sha256_file() { sha256sum "$1" | awk '{print $1}'; }
sha256_tree() { find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'; }
record_target() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STATE_TMP"; }

install_file() {
  local source=$1 target=$2
  if [[ -e $target || -L $target ]]; then
    if [[ $MODE == link && -L $target && $(readlink "$target") == "$source" ]]; then record_target link "$target" "$source"; return; fi
    if [[ $MODE == copy && -f $target ]] && cmp -s "$source" "$target"; then record_target copy "$target" "$(sha256_file "$target")"; return; fi
    [[ $FORCE == true ]] || die "target conflict: $target (use --force)"
    [[ $DRY_RUN == true ]] || rm -f "$target"
  fi
  note "Installing $target ($MODE)"
  if [[ $DRY_RUN == false ]]; then
    mkdir -p "$(dirname "$target")"
    if [[ $MODE == link ]]; then ln -s "$source" "$target"; else cp "$source" "$target"; fi
  fi
  if [[ $MODE == link ]]; then record_target link "$target" "$source"; else record_target copy "$target" "$(sha256_file "$source")"; fi
}

remove_recorded_targets() {
  local state=$1 kind target expected actual
  [[ -f $state ]] || return 0
  while IFS=$'\t' read -r kind target expected; do
    case $kind in
      link)
        if [[ -L $target && $(readlink "$target") == "$expected" ]]; then [[ $DRY_RUN == true ]] || rm "$target"
        elif [[ -e $target || -L $target ]]; then note "Preserving changed target: $target"; fi ;;
      copy)
        if [[ -f $target ]]; then
          actual=$(sha256_file "$target")
          if [[ $actual == "$expected" ]]; then [[ $DRY_RUN == true ]] || rm "$target"; else note "Preserving changed target: $target"; fi
        fi ;;
      bundle-link)
        if [[ -L $target && $(readlink "$target") == "$expected" ]]; then [[ $DRY_RUN == true ]] || rm "$target"
        elif [[ -e $target || -L $target ]]; then note "Preserving changed bundle: $target"; fi ;;
      bundle-copy)
        if [[ -d $target && ! -L $target ]]; then
          actual=$(sha256_tree "$target")
          if [[ $actual == "$expected" ]]; then [[ $DRY_RUN == true ]] || rm -rf "$target"; else note "Preserving changed bundle: $target"; fi
        fi ;;
    esac
  done < "$state"
}

remove_recorded_target() {
  local state=$1 selected=$2 kind target expected actual
  [[ -f $state ]] || return 0
  while IFS=$'\t' read -r kind target expected; do
    [[ $target == "$selected" ]] || continue
    case $kind in
      link)
        if [[ -L $target && $(readlink "$target") == "$expected" ]]; then [[ $DRY_RUN == true ]] || rm "$target"
        elif [[ -e $target || -L $target ]]; then note "Preserving changed target: $target"; fi ;;
      copy)
        if [[ -f $target ]]; then
          actual=$(sha256_file "$target")
          if [[ $actual == "$expected" ]]; then [[ $DRY_RUN == true ]] || rm "$target"; else note "Preserving changed target: $target"; fi
        fi ;;
    esac
  done < "$state"
}

prune_dir() { [[ $DRY_RUN == true ]] || rmdir "$1" 2>/dev/null || true; }

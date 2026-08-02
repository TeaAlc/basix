#!/usr/bin/env bash
# Status globals are an intentional return channel to the sourcing installers.
# shellcheck disable=SC2034

REPORT_ACTIVE=false REPORT_CHANGED=0 REPORT_UNCHANGED=0 REPORT_FAILED=0 REPORT_POINT='Operation'
report_color=false
if [[ -t 1 && -z ${NO_COLOR:-} && -z ${CI:-} ]]; then report_color=true; fi
report_paint() {
  local code=$1 text=$2
  if [[ $report_color == true ]]; then printf '\033[%sm%s\033[0m' "$code" "$text"; else printf '%s' "$text"; fi
}
report_header() { REPORT_ACTIVE=true; printf 'Basix installation report\n'; }
report_meta() { printf '%s: %s\n' "$1" "$2"; }
report_group() { printf '\n%s\n' "$1"; }
report_point() {
  local status=$1 label=$2 detail=${3:-} symbol color
  REPORT_POINT=$label
  case $status in
    changed) symbol='✓'; color=32; ((REPORT_CHANGED+=1)) ;;
    unchanged) symbol='-'; color=33; ((REPORT_UNCHANGED+=1)) ;;
    failed) symbol='✗'; color=31; ((REPORT_FAILED+=1)) ;;
  esac
  printf '  '; report_paint "$color" "$symbol"; printf ' %s' "$label"
  [[ -z $detail ]] || printf ' — %s' "$detail"
  printf '\n'
}
report_result() {
  report_group 'Result'
  if ((REPORT_FAILED)); then report_paint 31 '✗ Failed'; else report_paint 32 '✓ Complete'; fi
  printf ' — %d changed, %d unchanged, %d failed\n' "$REPORT_CHANGED" "$REPORT_UNCHANGED" "$REPORT_FAILED"
}
die() {
  if [[ $REPORT_ACTIVE == true ]]; then
    report_point failed "$REPORT_POINT" 'Failed safely'
    report_result
  else
    printf 'error: invalid request\n' >&2
  fi
  exit 1
}
note() { printf '%s\n' "$*"; }
orange_warning() { printf 'warning: %s\n' "$*" >&2; }
require_mode() { [[ $1 == link || $1 == copy ]] || die "invalid mode: $1"; }
choose_mode() {
  local default=$1 answer
  if [[ -t 0 && -t 1 ]]; then
    printf 'Installation mode [link/copy] (default: %s): ' "$default"
    read -r answer || answer=''
    case ${answer:-$default} in
      link|l|L) MODE='link' ;;
      copy|c|C) MODE='copy' ;;
      *) die "invalid mode: $answer" ;;
    esac
  else
    MODE=$default
  fi
}
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
codex_json_contains() {
  local needle=$1; shift
  local value
  value=$("$@" 2>/dev/null) || return 1
  python3 -c 'import json,sys
try: data=json.load(sys.stdin)
except (json.JSONDecodeError, TypeError): raise SystemExit(1)
raise SystemExit(0 if sys.argv[1] in json.dumps(data) else 1)' "$needle" <<<"$value"
}
marketplace_registered() { codex_json_contains 'basix-local' codex plugin marketplace list --json; }
marketplace_registered_at() { codex_json_contains "$1" codex plugin marketplace list --json; }
plugin_registered() { codex_json_contains 'basix@basix-local' codex plugin list --json || codex_json_contains 'basix-local' codex plugin list --json; }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }
filtered_files() {
  find -L "$1" \( -type d -name __pycache__ -prune \) -o \( -type f ! -name '*.pyc' ! -name '*.pyo' -print0 \)
}
sha256_tree() {
  (cd "$1" && filtered_files . | sort -z | xargs -0 -r sha256sum) | sha256sum | awk '{print $1}'
}
copy_filtered_tree() {
  local source=$1 target=$2
  mkdir -p "$target"
  (cd "$source" && tar -chf - --exclude=__pycache__ --exclude='*.pyc' --exclude='*.pyo' .) |
    (cd "$target" && tar -xf -)
}
filtered_project_files() {
  find -L "$1" \( -path "$1/plugin" -o -type d -name __pycache__ \) -prune -o \( -type f ! -name '*.pyc' ! -name '*.pyo' -print0 \)
}
record_target() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STATE_TMP"; }
canonical_path() { realpath -e -- "$1" 2>/dev/null || die "cannot resolve source (missing, unreadable, or symlink loop): $1"; }
same_physical_path() {
  local left right
  left=$(realpath -e -- "$1" 2>/dev/null) || return 1
  right=$(realpath -e -- "$2" 2>/dev/null) || return 1
  [[ $left == "$right" || $1 -ef $2 ]]
}
validate_source_tree() {
  local root=$1 bad
  canonical_path "$root" >/dev/null
  bad=$(find -L "$root" \( -type d -name __pycache__ -prune \) -o \( ! -name '*.pyc' ! -name '*.pyo' \( ! -readable -o ! -perm /444 -o -xtype l \) -print -quit \) 2>&1) || die "cannot validate source tree $root: $bad"
  [[ -z $bad ]] || die "unreadable source or symlink loop: $bad"
}

state_target_is_managed() {
  local state=$1 selected=$2 kind target expected
  [[ -f $state ]] || return 1
  while IFS=$'\t' read -r kind target expected; do
    [[ $target == "$selected" ]] || continue
    case $kind in
      link|copy|bundle-link|bundle-copy) return 0 ;;
    esac
  done < "$state"
  return 1
}

state_target_is_same() {
  local state=$1 selected=$2 kind target expected
  [[ -f $state ]] || return 1
  while IFS=$'\t' read -r kind target expected; do
    [[ $kind == same && $target == "$selected" ]] && return 0
  done < "$state"
  return 1
}

state_has_directory_link() {
  local state=$1 selected=$2 kind target expected
  [[ -f $state ]] || return 1
  while IFS=$'\t' read -r kind target expected; do
    [[ $kind == restore-dirlink && $target == "$selected" ]] && return 0
  done < "$state"
  return 1
}

# Refuse to traverse a foreign directory symlink while creating or removing a
# manifest target.  The installer may use a self-hosting directory link when
# its resolved parent is exactly the canonical source parent; every other
# symlink below INSTALL_TARGET_ROOT is treated as foreign.  The root itself is
# intentionally not inspected because CODEX_HOME/TARGET may be a user-owned
# symlink.
target_parent_is_safe() {
  local source=${1:-} target=$2 root=${INSTALL_TARGET_ROOT:-}
  [[ -n $root ]] || return 0
  python3 - "$source" "$target" "$root" <<'PY'
import os
import sys

source, target, root = sys.argv[1:]
target = os.path.abspath(target)
root = os.path.abspath(root)
parent = os.path.dirname(target)
try:
    if os.path.commonpath((parent, root)) != root:
        raise SystemExit(1)
except ValueError:
    raise SystemExit(1)

source_parent = os.path.realpath(os.path.dirname(source)) if source else None
relative = os.path.relpath(parent, root)
current = root
has_symlink = False
if relative != os.curdir:
    for component in relative.split(os.sep):
        current = os.path.join(current, component)
        if os.path.islink(current):
            has_symlink = True

if has_symlink:
    # A self-hosting target may intentionally resolve to the source parent.
    if source_parent is None or os.path.realpath(parent) != source_parent:
        raise SystemExit(1)
PY
}

manifest_target_is_safe() {
  local source=$1 target=$2
  target_parent_is_safe "$source" "$target" || return 1
  [[ -d $target && ! -L $target ]] && return 1
  return 0
}

remove_managed_object() {
  local target=$1 kind=$2
  if [[ -L $target || -f $target ]]; then
    [[ $DRY_RUN == true ]] || rm -f -- "$target"
  elif [[ -d $target && $kind == bundle-copy ]]; then
    [[ $DRY_RUN == true ]] || rm -rf -- "$target"
  elif [[ -e $target ]]; then
    die "refusing to recursively replace managed non-bundle directory: $target"
  fi
}

install_file() {
  local source=$1 target=$2
  INSTALL_RESULT=changed
  [[ -r $source ]] || die "source is not readable: $source"
  canonical_path "$source" >/dev/null
  manifest_target_is_safe "$source" "$target" || die "foreign directory link or directory target protected: $target"
  if [[ -e $target || -L $target ]]; then
    if [[ $MODE == link && -L $target && $(readlink "$target") == "$source" ]]; then INSTALL_RESULT=unchanged; record_target link "$target" "$source"; return; fi
    if { [[ $MODE == link ]] || [[ ! -L $target ]]; } && same_physical_path "$source" "$target"; then
      INSTALL_RESULT=unchanged
      record_target same "$target" "$(canonical_path "$source")"
      return
    fi
    if [[ $MODE == copy && -f $target && ! -L $target ]] && cmp -s "$source" "$target"; then INSTALL_RESULT=unchanged; record_target copy "$target" "$(sha256_file "$target")"; return; fi
    # Every target passed to install_file is an exact current-manifest target.
    # Declarative installation therefore converges it without requiring old
    # state or --force.  Physical aliases were handled above and are never
    # removed; a real directory remains protected from recursive replacement.
    if [[ -d $target && ! -L $target ]]; then die "refusing to replace directory target: $target"; fi
    [[ $DRY_RUN == true ]] || rm -f -- "$target"
  fi
  if [[ $DRY_RUN == false ]]; then
    mkdir -p "$(dirname "$target")"
    if [[ $MODE == link ]]; then ln -s "$source" "$target"; else cp "$source" "$target"; fi
  fi
  if [[ $MODE == link ]]; then record_target link "$target" "$source"; else record_target copy "$target" "$(sha256_file "$source")"; fi
}

path_is_below() {
  local path root
  path=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")
  root=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$2")
  [[ $path == "$root/"* ]]
}

path_is_within() {
  local path root
  path=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")
  root=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$2")
  [[ $path == "$root" || $path == "$root/"* ]]
}

path_is_within_any() {
  local path=$1 root
  shift
  for root in "$@"; do
    path_is_within "$path" "$root" && return 0
  done
  return 1
}

reconcile_stale_targets() {
  local old_state=$1 new_state=$2 agents_root=$3 skills_root=$4 ignored_root=${5:-} kind target expected
  [[ -f $old_state ]] || return 0
  while IFS=$'\t' read -r kind target expected; do
    case $kind in link|copy) ;; *) continue ;; esac
    if ! path_is_below "$target" "$agents_root" && ! path_is_below "$target" "$skills_root"; then
      [[ -n $ignored_root ]] && path_is_below "$target" "$ignored_root" && continue
      orange_warning "Ignoring out-of-scope installer state path: $target"
      continue
    fi
    awk -F '\t' -v selected="$target" '$2 == selected { found = 1 } END { exit !found }' "$new_state" && continue
    target_parent_is_safe '' "$target" || { orange_warning "Preserving stale target below foreign directory link: $target"; continue; }
    STALE_CHANGED=true
    remove_managed_object "$target" "$kind"
  done < "$old_state"
}

remove_recorded_targets() {
  local state=$1 kind target expected actual
  shift
  local -a allowed_roots=("$@")
  [[ -f $state ]] || return 0
  while IFS=$'\t' read -r kind target expected; do
    [[ $kind == same ]] && continue
    if (( ${#allowed_roots[@]} )) && ! path_is_within_any "$target" "${allowed_roots[@]}"; then
      orange_warning "Preserving out-of-scope installer state path: $target"
      REMOVE_PRESERVED=true
      continue
    fi
    target_parent_is_safe '' "$target" || { orange_warning "Preserving target below foreign directory link: $target"; REMOVE_PRESERVED=true; continue; }
    case $kind in
      link)
        if [[ -L $target && $(readlink "$target") == "$expected" ]]; then REMOVE_CHANGED=true; [[ $DRY_RUN == true ]] || rm "$target"
        elif [[ -e $target || -L $target ]]; then REMOVE_PRESERVED=true; fi ;;
      copy)
        if [[ -f $target && ! -L $target ]]; then
          actual=$(sha256_file "$target")
          if [[ $actual == "$expected" ]]; then REMOVE_CHANGED=true; [[ $DRY_RUN == true ]] || rm "$target"; else REMOVE_PRESERVED=true; fi
        elif [[ -e $target || -L $target ]]; then REMOVE_PRESERVED=true
        fi ;;
      bundle-link)
        if [[ -L $target && $(readlink "$target") == "$expected" ]]; then REMOVE_CHANGED=true; [[ $DRY_RUN == true ]] || rm "$target"
        elif [[ -e $target || -L $target ]]; then REMOVE_PRESERVED=true; fi ;;
      bundle-copy)
        if [[ -d $target && ! -L $target ]]; then
          actual=$(sha256_tree "$target")
          if [[ $actual == "$expected" ]]; then REMOVE_CHANGED=true; [[ $DRY_RUN == true ]] || rm -rf "$target"; else REMOVE_PRESERVED=true; fi
        elif [[ -e $target || -L $target ]]; then REMOVE_PRESERVED=true
        fi ;;
      same) : ;;
    esac
  done < "$state"
}

recorded_removal_status() {
  local state=$1 selected=$2 kind target expected actual
  [[ -f $state ]] || { printf 'absent\n'; return; }
  while IFS=$'\t' read -r kind target expected; do
    [[ $target == "$selected" ]] || continue
    [[ $kind == same ]] && { printf 'preserved\n'; return; }
    target_parent_is_safe '' "$target" || { printf 'preserved\n'; return; }
    case $kind in
      link|bundle-link)
        [[ -L $target && $(readlink "$target") == "$expected" ]] && { printf 'changed\n'; return; }
        [[ -e $target || -L $target ]] && { printf 'preserved\n'; return; } ;;
      copy)
        if [[ -f $target && ! -L $target ]]; then actual=$(sha256_file "$target"); [[ $actual == "$expected" ]] && printf 'changed\n' || printf 'preserved\n'; return;
        elif [[ -e $target || -L $target ]]; then printf 'preserved\n'; return; fi ;;
      bundle-copy)
        if [[ -d $target && ! -L $target ]]; then actual=$(sha256_tree "$target"); [[ $actual == "$expected" ]] && printf 'changed\n' || printf 'preserved\n'; return;
        elif [[ -e $target || -L $target ]]; then printf 'preserved\n'; return; fi ;;
      same) printf 'preserved\n'; return ;;
    esac
  done < "$state"
  printf 'absent\n'
}

remove_recorded_target() {
  local state=$1 selected=$2 kind target expected actual
  [[ -f $state ]] || return 0
  while IFS=$'\t' read -r kind target expected; do
    [[ $target == "$selected" ]] || continue
    target_parent_is_safe '' "$target" || { orange_warning "Preserving target below foreign directory link: $target"; return 0; }
    case $kind in
      link)
        if [[ -L $target && $(readlink "$target") == "$expected" ]]; then [[ $DRY_RUN == true ]] || rm "$target"
        elif [[ -e $target || -L $target ]]; then note "Preserving changed target: $target"; fi ;;
      copy)
        if [[ -f $target && ! -L $target ]]; then
          actual=$(sha256_file "$target")
          if [[ $actual == "$expected" ]]; then [[ $DRY_RUN == true ]] || rm "$target"; else note "Preserving changed target: $target"; fi
        elif [[ -e $target || -L $target ]]; then note "Preserving changed target: $target"
        fi ;;
    esac
  done < "$state"
}

prune_dir() { [[ $DRY_RUN == true ]] || rmdir "$1" 2>/dev/null || true; }

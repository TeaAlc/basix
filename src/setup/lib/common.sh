#!/usr/bin/env bash
# Status globals are an intentional return channel to the sourcing installers.
# shellcheck disable=SC2034

export PYTHONDONTWRITEBYTECODE=1

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
  find "$1" \( -type d -name __pycache__ -prune \) -o \( -type f ! -name '*.pyc' ! -name '*.pyo' -print0 \)
}
sha256_tree() {
  (cd "$1" && filtered_files . | sort -z | xargs -0 -r sha256sum) | sha256sum | awk '{print $1}'
}
copy_filtered_tree() {
  local source=$1 target=$2
  mkdir -p "$target"
  (cd "$source" && tar -cf - --exclude=__pycache__ --exclude='*.pyc' --exclude='*.pyo' .) |
    (cd "$target" && tar -xf -)
}
filtered_project_files() {
  find -L "$1" \( -path "$1/plugin" -o -type d -name __pycache__ \) -prune -o \( -type f ! -name '*.pyc' ! -name '*.pyo' -print0 \)
}
record_target() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STATE_TMP"; }
record_tree_file() { printf 'dirfile\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STATE_TMP"; }
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
  bad=$(find "$root" \( -type d -name __pycache__ -prune \) -o \( ! -name '*.pyc' ! -name '*.pyo' \( -type l -o \( ! -type d ! -type f \) -o ! -readable -o ! -perm /444 \) -print -quit \) 2>&1) || die "cannot validate source tree $root: $bad"
  [[ -z $bad ]] || die "source tree contains an unreadable, linked, or special node: $bad"
}

state_target_is_managed() {
  local state=$1 selected=$2 kind target expected
  [[ -f $state ]] || return 1
  while IFS=$'\t' read -r kind target expected; do
    [[ $target == "$selected" ]] || continue
    case $kind in
      link|copy|bundle-link|bundle-copy|dirlink|dircopy) return 0 ;;
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
  [[ -L $target && -d $target ]] && return 1
  [[ -d $target && ! -L $target ]] && return 1
  return 0
}

remove_managed_object() {
  local target=$1 kind=$2
  if [[ -L $target || -f $target ]]; then
    [[ $DRY_RUN == true ]] || rm -f -- "$target"
  elif [[ -d $target && ( $kind == bundle-copy || $kind == dircopy ) ]]; then
    [[ $DRY_RUN == true ]] || rm -rf -- "$target"
  elif [[ -e $target ]]; then
    die "refusing to recursively replace managed non-bundle directory: $target"
  fi
}

state_directory_kind() {
  local state=$1 selected=$2 kind target expected
  [[ -f $state ]] || return 1
  while IFS=$'\t' read -r kind target expected; do
    [[ $target == "$selected" && ( $kind == dirlink || $kind == dircopy ) ]] || continue
    printf '%s\n' "$kind"
    return 0
  done < "$state"
  return 1
}

tree_has_only_source_paths() {
  local source=$1 target=$2
  [[ -d $target && ! -L $target ]] || return 1
  python3 - "$source" "$target" <<'PY'
import os
import stat
import sys

source, target = map(os.path.abspath, sys.argv[1:])
for root, directories, files in os.walk(target, followlinks=False):
    relative_root = os.path.relpath(root, target)
    for name in directories + files:
        relative = os.path.normpath(os.path.join(relative_root, name))
        if relative == os.curdir:
            relative = name
        source_path = os.path.join(source, relative)
        target_path = os.path.join(target, relative)
        if not os.path.lexists(source_path):
            raise SystemExit(1)
        source_mode = os.lstat(source_path).st_mode
        target_mode = os.lstat(target_path).st_mode
        source_regular = stat.S_ISREG(source_mode)
        target_regular = stat.S_ISREG(target_mode)
        source_directory = stat.S_ISDIR(source_mode)
        target_directory = stat.S_ISDIR(target_mode)
        if stat.S_ISLNK(target_mode) and source_regular:
            if os.path.realpath(target_path) == os.path.realpath(source_path):
                continue
        if not ((source_regular and target_regular) or (source_directory and target_directory)):
            raise SystemExit(1)
PY
}

directory_link_matches() {
  local target=$1 expected=$2 actual
  [[ -L $target ]] || return 1
  actual=$(realpath -e -- "$target" 2>/dev/null) || return 1
  [[ $actual == "$expected" ]]
}

record_tree_inventory() {
  local source=$1 target=$2 file relative
  while IFS= read -r -d '' file; do
    relative=${file#"$source/"}
    record_tree_file "$target" "$relative" "$(sha256_file "$file")"
  done < <(filtered_files "$source" | sort -z)
}

install_tree() {
  local source=$1 target=$2 canonical current_kind='' actual
  canonical=$(canonical_path "$source")
  validate_source_tree "$canonical"
  target_parent_is_safe '' "$target" || die "foreign directory-link parent protected: $target"
  if [[ -e $target || -L $target ]]; then
    if same_physical_path "$canonical" "$target" &&
       { [[ ! -L $target ]] || ! directory_link_matches "$target" "$canonical"; }; then
      die "canonical source alias protected: $target"
    fi
  fi
  INSTALL_RESULT=changed
  current_kind=$(state_directory_kind "${STATE:-}" "$target" 2>/dev/null || true)

  if [[ $MODE == link ]]; then
    if directory_link_matches "$target" "$canonical"; then
      INSTALL_RESULT=unchanged
      record_target dirlink "$target" "$canonical"
      return
    fi
    if [[ -L $target ]]; then
      [[ $current_kind == dirlink || $current_kind == dircopy ]] || die "foreign directory link protected: $target"
      [[ $DRY_RUN == true ]] || rm -- "$target"
    elif [[ -d $target ]]; then
      tree_has_only_source_paths "$canonical" "$target" || die "foreign content in managed directory protected: $target"
      [[ $DRY_RUN == true ]] || rm -rf -- "$target"
    elif [[ -e $target ]]; then
      die "non-directory target protected: $target"
    fi
    if [[ $DRY_RUN == false ]]; then
      mkdir -p "$(dirname "$target")"
      ln -s "$canonical" "$target"
    fi
    record_target dirlink "$target" "$canonical"
    return
  fi

  if [[ -L $target ]]; then
    if [[ $current_kind != dirlink && $current_kind != dircopy ]] && ! directory_link_matches "$target" "$canonical"; then
      die "foreign directory link protected: $target"
    fi
    [[ $DRY_RUN == true ]] || rm -- "$target"
  elif [[ -d $target ]]; then
    tree_has_only_source_paths "$canonical" "$target" || die "foreign content in managed directory protected: $target"
    actual=$(sha256_tree "$target")
    if [[ $actual == "$(sha256_tree "$canonical")" ]]; then
      INSTALL_RESULT=unchanged
      record_target dircopy "$target" "$actual"
      record_tree_inventory "$canonical" "$target"
      return
    fi
    [[ $DRY_RUN == true ]] || rm -rf -- "$target"
  elif [[ -e $target ]]; then
    die "non-directory target protected: $target"
  fi
  if [[ $DRY_RUN == false ]]; then copy_filtered_tree "$canonical" "$target"; fi
  record_target dircopy "$target" "$(sha256_tree "$canonical")"
  record_tree_inventory "$canonical" "$target"
}

preflight_tree() {
  local source=$1 target=$2 canonical current_kind=''
  canonical=$(canonical_path "$source")
  validate_source_tree "$canonical"
  target_parent_is_safe '' "$target" || die "foreign directory-link parent protected: $target"
  if [[ -e $target || -L $target ]]; then
    if same_physical_path "$canonical" "$target" &&
       { [[ ! -L $target ]] || ! directory_link_matches "$target" "$canonical"; }; then
      die "canonical source alias protected: $target"
    fi
  fi
  current_kind=$(state_directory_kind "${STATE:-}" "$target" 2>/dev/null || true)
  if [[ -L $target ]]; then
    if directory_link_matches "$target" "$canonical"; then return 0; fi
    [[ $current_kind == dirlink || $current_kind == dircopy ]] || die "foreign directory link protected: $target"
  elif [[ -d $target ]]; then
    tree_has_only_source_paths "$canonical" "$target" || die "foreign content in managed directory protected: $target"
  elif [[ -e $target ]]; then
    die "non-directory target protected: $target"
  fi
}

relative_managed_path_is_safe() {
  local relative=$1
  [[ -n $relative && $relative != /* && $relative != . && $relative != .. &&
     $relative != ../* && $relative != */../* && $relative != */.. &&
     $relative != *$'\t'* && $relative != *$'\n'* && $relative != *'//'* ]]
}

managed_file_matches() {
  local root=$1 relative=$2 expected=$3 parent current component
  local -a components=()
  relative_managed_path_is_safe "$relative" || return 1
  [[ -d $root && ! -L $root ]] || return 1
  parent=${relative%/*}
  current=$root
  if [[ $parent != "$relative" ]]; then
    local IFS=/
    read -r -a components <<< "$parent"
    for component in "${components[@]}"; do
      [[ -n $component ]] || return 1
      current="$current/$component"
      [[ -d $current && ! -L $current ]] || return 1
    done
  fi
  current="$root/$relative"
  [[ -f $current && ! -L $current ]] || return 1
  [[ $(sha256_file "$current") == "$expected" ]]
}

managed_directory_is_safe() {
  local root=$1 relative=$2 current component
  local -a components=()
  current=$root
  relative_managed_path_is_safe "$relative" || return 1
  [[ -d $root && ! -L $root ]] || return 1
  local IFS=/
  read -r -a components <<< "$relative"
  for component in "${components[@]}"; do
    [[ -n $component ]] || return 1
    current="$current/$component"
    [[ -d $current && ! -L $current ]] || return 1
  done
}

tree_has_only_regular_files_and_directories() {
  local root=$1
  [[ -d $root && ! -L $root ]] || return 1
  ! find "$root" -mindepth 1 \( -type l -o \( ! -type d ! -type f \) \) -print -quit | grep -q .
}

state_has_tree_inventory() {
  local state=$1 selected=$2 kind target relative expected
  [[ -f $state ]] || return 1
  while IFS=$'\t' read -r kind target relative expected; do
    [[ $kind == dirfile && $target == "$selected" ]] && return 0
  done < "$state"
  return 1
}

tree_inventory_has_removable_file() {
  local state=$1 selected=$2 source=${3:-} kind target relative expected file
  if state_has_tree_inventory "$state" "$selected"; then
    while IFS=$'\t' read -r kind target relative expected; do
      [[ $kind == dirfile && $target == "$selected" ]] || continue
      managed_file_matches "$selected" "$relative" "$expected" && return 0
    done < "$state"
  elif [[ -n $source && -d $source && ! -L $source ]]; then
    while IFS= read -r -d '' file; do
      relative=${file#"$source/"}
      managed_file_matches "$selected" "$relative" "$(sha256_file "$file")" && return 0
    done < <(filtered_files "$source" | sort -z)
  fi
  return 1
}

directory_removal_status() {
  local state=$1 selected=$2 source=${3:-} kind target expected ignored actual
  [[ -f $state ]] || { printf 'absent\n'; return; }
  target_parent_is_safe '' "$selected" || { printf 'preserved\n'; return; }
  if [[ -n $source && ! -L $selected && -e $selected ]]; then
    same_physical_path "$source" "$selected" && { printf 'preserved\n'; return; }
  fi
  # Nested helpers reopen state read-only; no command writes it in this loop.
  # shellcheck disable=SC2094
  while IFS=$'\t' read -r kind target expected ignored; do
    [[ $target == "$selected" ]] || continue
    case $kind in
      dirlink)
        if [[ -n $source ]] && [[ $expected == "$(canonical_path "$source")" ]] && directory_link_matches "$target" "$expected"; then
          printf 'changed\n'
        elif [[ -e $target || -L $target ]]; then printf 'preserved\n'; else printf 'absent\n'; fi
        return ;;
      dircopy)
        if [[ -d $target && ! -L $target ]]; then
          if state_has_tree_inventory "$state" "$selected"; then
            if [[ -n $source && -d $source && ! -L $source ]] &&
               tree_has_only_source_paths "$source" "$target" &&
               [[ $(sha256_tree "$target") == "$expected" ]]; then
              printf 'changed\n'
            elif tree_inventory_has_removable_file "$state" "$selected" "$source"; then printf 'partial\n'; else printf 'preserved\n'; fi
          elif tree_has_only_regular_files_and_directories "$target"; then
            actual=$(sha256_tree "$target")
            if [[ $actual == "$expected" ]]; then
              printf 'changed\n'
            elif tree_inventory_has_removable_file "$state" "$selected" "$source"; then
              printf 'partial\n'
            else
              printf 'preserved\n'
            fi
          elif tree_inventory_has_removable_file "$state" "$selected" "$source"; then
            printf 'partial\n'
          else printf 'preserved\n'; fi
        elif [[ -e $target || -L $target ]]; then printf 'preserved\n'; else printf 'absent\n'; fi
        return ;;
    esac
  done < "$state"
  printf 'absent\n'
}

remove_recorded_directory() {
  local state=$1 selected=$2 source=${3:-} status kind target relative expected file
  status=$(directory_removal_status "$state" "$selected" "$source")
  case $status in
    changed)
      if [[ $DRY_RUN == false ]]; then
        if [[ -L $selected ]]; then rm -- "$selected"; else rm -rf -- "$selected"; fi
      fi ;;
    partial)
      if state_has_tree_inventory "$state" "$selected"; then
        while IFS=$'\t' read -r kind target relative expected; do
          [[ $kind == dirfile && $target == "$selected" ]] || continue
          if managed_file_matches "$selected" "$relative" "$expected"; then
            [[ $DRY_RUN == true ]] || rm -- "$selected/$relative"
          fi
        done < "$state"
      elif [[ -n $source && -d $source && ! -L $source ]]; then
        while IFS= read -r -d '' file; do
          relative=${file#"$source/"}
          expected=$(sha256_file "$file")
          if managed_file_matches "$selected" "$relative" "$expected"; then
            [[ $DRY_RUN == true ]] || rm -- "$selected/$relative"
          fi
        done < <(filtered_files "$source" | sort -z)
      fi
      if [[ $DRY_RUN == false ]]; then
        if state_has_tree_inventory "$state" "$selected"; then
          while IFS=$'\t' read -r kind target relative expected; do
            [[ $kind == dirfile && $target == "$selected" ]] || continue
            relative_managed_path_is_safe "$relative" || continue
            while [[ $relative == */* ]]; do
              relative=${relative%/*}
              managed_directory_is_safe "$selected" "$relative" || continue
              rmdir -- "$selected/$relative" 2>/dev/null || true
            done
          done < "$state"
        elif [[ -n $source && -d $source && ! -L $source ]]; then
          while IFS= read -r -d '' file; do
            relative=${file#"$source/"}
            while [[ $relative == */* ]]; do
              relative=${relative%/*}
              managed_directory_is_safe "$selected" "$relative" || continue
              rmdir -- "$selected/$relative" 2>/dev/null || true
            done
          done < <(filtered_files "$source" | sort -z)
        fi
        rmdir -- "$selected" 2>/dev/null || true
      fi ;;
  esac
}

migrate_shared_agent_files() {
  local state=$1 shared=$2 source_root=$3 source target managed
  while IFS= read -r -d '' source; do
    target="$shared/$(basename "$source")"
    target_parent_is_safe '' "$target" || { orange_warning "Preserving shared agent below foreign directory link: $target"; continue; }
    [[ -e $target || -L $target ]] || continue
    managed=false
    state_target_is_managed "$state" "$target" && managed=true
    if [[ -L $target ]]; then
      if [[ $managed == true ]] || directory_link_matches "$target" "$(canonical_path "$source")"; then
        [[ $DRY_RUN == true ]] || rm -- "$target"
      fi
    elif [[ -f $target ]] && { [[ $managed == true ]] || cmp -s "$source" "$target"; }; then
      [[ $DRY_RUN == true ]] || rm -- "$target"
    fi
  done < <(find -L "$source_root" -maxdepth 1 -type f -name '*.toml' -print0 | sort -z)
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

path_is_below_any() {
  local path=$1 root
  shift
  for root in "$@"; do
    path_is_below "$path" "$root" && return 0
  done
  return 1
}

mark_processed_directory() {
  REMOVE_PROCESSED_DIRECTORIES+="${REMOVE_PROCESSED_DIRECTORIES:+$'\n'}$1"
}

directory_was_processed() {
  local selected=$1 recorded
  while IFS= read -r recorded; do
    [[ $recorded == "$selected" ]] && return 0
  done <<< "${REMOVE_PROCESSED_DIRECTORIES:-}"
  return 1
}

reconcile_stale_targets() {
  local old_state=$1 new_state=$2 agents_root=$3 skills_root=$4 ignored_root=${5:-} kind target expected actual status
  [[ -f $old_state ]] || return 0
  # Nested helpers reopen old state read-only; no command writes it here.
  # shellcheck disable=SC2094
  while IFS=$'\t' read -r kind target expected; do
    case $kind in link|copy|dirlink|dircopy) ;; *) continue ;; esac
    awk -F '\t' -v selected="$target" '$2 == selected { found = 1 } END { exit !found }' "$new_state" && continue
    if ! path_is_below "$target" "$agents_root" && ! path_is_below "$target" "$skills_root"; then
      [[ -n $ignored_root ]] && path_is_below "$target" "$ignored_root" && continue
      orange_warning "Ignoring out-of-scope installer state path: $target"
      continue
    fi
    target_parent_is_safe '' "$target" || { orange_warning "Preserving stale target below foreign directory link: $target"; continue; }
    case $kind in
      link)
        if [[ -L $target && $(readlink "$target") == "$expected" ]]; then
          STALE_CHANGED=true; [[ $DRY_RUN == true ]] || rm -- "$target"
        elif [[ -e $target || -L $target ]]; then orange_warning "Preserving changed stale target: $target"; fi ;;
      copy)
        if [[ -f $target && ! -L $target ]]; then
          actual=$(sha256_file "$target")
          if [[ $actual == "$expected" ]]; then STALE_CHANGED=true; [[ $DRY_RUN == true ]] || rm -- "$target"
          else orange_warning "Preserving changed stale target: $target"; fi
        elif [[ -e $target || -L $target ]]; then orange_warning "Preserving changed stale target: $target"; fi ;;
      dirlink)
        if [[ -L $target && $(readlink "$target") == "$expected" ]]; then
          STALE_CHANGED=true; [[ $DRY_RUN == true ]] || rm -- "$target"
        elif [[ -e $target || -L $target ]]; then orange_warning "Preserving redirected stale directory link: $target"; fi ;;
      dircopy)
        status=$(directory_removal_status "$old_state" "$target")
        case $status in
          changed|partial) STALE_CHANGED=true; remove_recorded_directory "$old_state" "$target" ;;
          preserved) orange_warning "Preserving changed or foreign content in stale directory: $target" ;;
        esac ;;
    esac
  done < "$old_state"
}

remove_recorded_targets() {
  local state=$1 kind target expected actual status
  shift
  local -a allowed_roots=("$@")
  [[ -f $state ]] || return 0
  # Nested helpers reopen state read-only; no command writes it in this loop.
  # shellcheck disable=SC2094
  while IFS=$'\t' read -r kind target expected; do
    [[ $kind == same ]] && continue
    [[ $kind == dirfile ]] && continue
    if [[ $kind == dircopy || $kind == dirlink ]] && directory_was_processed "$target"; then continue; fi
    [[ -n ${REMOVE_EXCLUDED_TARGET:-} && $target == "$REMOVE_EXCLUDED_TARGET" ]] && continue
    # Allowed roots are ownership boundaries, never removable state targets.
    # Only their strict descendants can be selected by installer state.
    if (( ${#allowed_roots[@]} )) && ! path_is_below_any "$target" "${allowed_roots[@]}"; then
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
      dircopy)
        if state_has_tree_inventory "$state" "$target"; then
          status=$(directory_removal_status "$state" "$target")
          case $status in
            changed) REMOVE_CHANGED=true ;;
            partial) REMOVE_CHANGED=true ;;
            preserved) REMOVE_PRESERVED=true ;;
          esac
          remove_recorded_directory "$state" "$target"
          if [[ $status == partial && ( -e $target || -L $target ) ]]; then REMOVE_PRESERVED=true; fi
        elif [[ -d $target && ! -L $target ]] && tree_has_only_regular_files_and_directories "$target"; then
          actual=$(sha256_tree "$target")
          if [[ $actual == "$expected" ]]; then
            REMOVE_CHANGED=true
            [[ $DRY_RUN == true ]] || rm -rf -- "$target"
          else REMOVE_PRESERVED=true; fi
        elif [[ -e $target || -L $target ]]; then REMOVE_PRESERVED=true; fi ;;
      dirlink|dirfile)
        # Directory records are removed only by remove_recorded_directory,
        # whose caller supplies the canonical Basix source for ownership.
        : ;;
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
      dirlink)
        directory_link_matches "$target" "$expected" && printf 'changed\n' || printf 'preserved\n'; return ;;
      dircopy)
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

prune_dir() {
  [[ $DRY_RUN == true ]] && return 0
  target_parent_is_safe '' "$1" || return 0
  [[ -d $1 && ! -L $1 ]] || return 0
  rmdir -- "$1" 2>/dev/null || true
}

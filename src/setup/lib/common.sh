#!/usr/bin/env bash
# Status globals are an intentional return channel to the sourcing installers.
# shellcheck disable=SC2034

export PYTHONDONTWRITEBYTECODE=1

REPORT_ACTIVE=false REPORT_CHANGED=0 REPORT_UNCHANGED=0 REPORT_FAILED=0 REPORT_POINT='Operation'
report_color=false
if [[ -t 1 && -n ${TERM:-} && ${TERM:-} != dumb && -z ${NO_COLOR:-} && -z ${CI:-} ]]; then report_color=true; fi
report_paint() { local code=$1 text=$2; if [[ $report_color == true ]]; then printf '\033[%sm%s\033[0m' "$code" "$text"; else printf '%s' "$text"; fi; }
report_header() { REPORT_ACTIVE=true; printf 'Basix installation report\n'; }
report_meta() { printf '%s: %s\n' "$1" "$2"; }
report_group() { printf '\n%s\n' "$1"; }
report_point() {
  local status=$1 label=$2 detail=${3:-} symbol color
  REPORT_POINT=$label
  case $status in changed) symbol='✓'; color=32; ((REPORT_CHANGED+=1)) ;; unchanged) symbol='-'; color=33; ((REPORT_UNCHANGED+=1)) ;; failed) symbol='✗'; color=31; ((REPORT_FAILED+=1)) ;; esac
  printf '  '; report_paint "$color" "$symbol"; printf ' %s' "$label"; [[ -z $detail ]] || printf ' — %s' "$detail"; printf '\n'
}
prepare_agent_tree_report() {
  local source=$1 target=$2 agent name detail
  AGENT_REPORT_NAMES=() AGENT_REPORT_DETAILS=()
  while IFS= read -r -d '' agent; do
    name=$(basename "$agent")
    if [[ ! -e "$target/$name" ]]; then
      detail=installed
    elif cmp -s "$agent" "$target/$name"; then
      detail=unchanged
    else
      detail=updated
    fi
    AGENT_REPORT_NAMES+=("$name") AGENT_REPORT_DETAILS+=("$detail")
  done < <(find "$source" -mindepth 1 -maxdepth 1 -type f -name '*.toml' -print0 | sort -z)
}
report_agent_tree() {
  local index detail status
  for index in "${!AGENT_REPORT_NAMES[@]}"; do
    detail=${AGENT_REPORT_DETAILS[index]}
    [[ $detail == unchanged ]] && status=unchanged || status=changed
    report_point "$status" "${AGENT_REPORT_NAMES[index]}" "$detail"
  done
}
report_result() { report_group 'Result'; if ((REPORT_FAILED)); then report_paint 31 '✗ Failed'; else report_paint 32 '✓ Complete'; fi; printf ' — %d changed, %d unchanged, %d failed\n' "$REPORT_CHANGED" "$REPORT_UNCHANGED" "$REPORT_FAILED"; }
die() { if [[ $REPORT_ACTIVE == true ]]; then report_point failed "$REPORT_POINT" 'Failed safely'; report_result; else printf 'error: invalid request\n' >&2; fi; exit 1; }
note() { printf '%s\n' "$*"; }
orange_warning() { printf 'warning: %s\n' "$*" >&2; }

lumen_mcp_registration_status() {
  local expected_command=$1 metadata
  command -v codex >/dev/null || return 1
  if ! metadata=$(codex mcp get lumen --json 2>/dev/null); then
    printf 'absent\n'
    return 0
  fi
  python3 -c 'import json,sys
try:
 value=json.load(sys.stdin)
 transport=value.get("transport", {})
 matching=(value.get("name")=="lumen" and value.get("enabled") is True and value.get("disabled_reason") is None and transport.get("command")==sys.argv[1] and transport.get("args")==["stdio"])
except (AttributeError,json.JSONDecodeError): matching=False
print("matching" if matching else "conflict")' "$expected_command" <<<"$metadata"
}

lumen_mcp_installed() { [[ $(lumen_mcp_registration_status "$1") == matching ]]; }

codex_json_contains() { local needle=$1 value; shift; value=$("$@" 2>/dev/null) || return 1; python3 -c 'import json,sys
try: data=json.load(sys.stdin)
except (json.JSONDecodeError,TypeError): raise SystemExit(1)
raise SystemExit(0 if sys.argv[1] in json.dumps(data) else 1)' "$needle" <<<"$value"; }
marketplace_registered() { codex_json_contains 'basix-local' codex plugin marketplace list --json; }
marketplace_registered_at() { codex_json_contains "$1" codex plugin marketplace list --json; }
plugin_registered() { codex_json_contains 'basix@basix-local' codex plugin list --json || codex_json_contains 'basix-local' codex plugin list --json; }

sha256_file() { sha256sum "$1" | awk '{print $1}'; }
filtered_files() { find "$1" \( -type d -name __pycache__ -prune \) -o \( -type f ! -name '*.pyc' ! -name '*.pyo' -print0 \); }
sha256_tree() { (cd "$1" && filtered_files . | sort -z | xargs -0 -r sha256sum) | sha256sum | awk '{print $1}'; }
copy_filtered_tree() { local source=$1 target=$2; mkdir -p "$target"; (cd "$source" && tar -cf - --exclude=__pycache__ --exclude='*.pyc' --exclude='*.pyo' .) | (cd "$target" && tar -xf -); }
record_target() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STATE_TMP"; }
record_tree_file() { printf 'dirfile\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STATE_TMP"; }
canonical_path() { realpath -e -- "$1" 2>/dev/null || die; }
same_physical_path() { local left right; left=$(realpath -e -- "$1" 2>/dev/null) || return 1; right=$(realpath -e -- "$2" 2>/dev/null) || return 1; [[ $left == "$right" || $1 -ef $2 ]]; }
validate_source_tree() {
  local root=$1 bad
  canonical_path "$root" >/dev/null
  bad=$(find "$root" \( -type d -name __pycache__ -prune \) -o \( ! -name '*.pyc' ! -name '*.pyo' \( -type l -o \( ! -type d ! -type f \) -o ! -readable -o ! -perm /444 \) -print -quit \) 2>&1) || die
  [[ -z $bad ]] || die
}
target_parent_is_safe() {
  local target=$2 root=${INSTALL_TARGET_ROOT:-}
  [[ -n $root ]] || return 0
  python3 - "$target" "$root" <<'PY'
import os,sys
target,root=map(os.path.abspath,sys.argv[1:])
parent=os.path.dirname(target)
try:
    if os.path.commonpath((parent,root)) != root: raise SystemExit(1)
except ValueError: raise SystemExit(1)
relative=os.path.relpath(parent,root); current=root
if relative != os.curdir:
    for part in relative.split(os.sep):
        current=os.path.join(current,part)
        if os.path.islink(current): raise SystemExit(1)
PY
}
manifest_target_is_safe() { target_parent_is_safe '' "$2" || return 1; [[ ! -L $2 && ! -d $2 ]]; }
preflight_file() {
  local source=$1 target=$2
  [[ -r $source ]] || die; canonical_path "$source" >/dev/null; manifest_target_is_safe "$source" "$target" || die
  if [[ -e $target ]]; then
    same_physical_path "$source" "$target" && die
    [[ -f $target && ! -L $target ]] || die
    cmp -s "$source" "$target" || state_target_is_managed "${STATE:-}" "$target" || die
  fi
}
state_target_is_managed() { local state=$1 selected=$2 kind target ignored; [[ -f $state ]] || return 1; while IFS=$'\t' read -r kind target ignored; do [[ $kind == copy && $target == "$selected" ]] && return 0; done < "$state"; return 1; }
state_directory_is_managed() { local state=$1 selected=$2 kind target ignored; [[ -f $state ]] || return 1; while IFS=$'\t' read -r kind target ignored; do [[ $kind == dircopy && $target == "$selected" ]] && return 0; done < "$state"; return 1; }
tree_has_only_source_paths() {
  local source=$1 target=$2
  [[ -d $target && ! -L $target ]] || return 1
  python3 - "$source" "$target" <<'PY'
import os,stat,sys
source,target=map(os.path.abspath,sys.argv[1:])
for root,dirs,files in os.walk(target,followlinks=False):
    relroot=os.path.relpath(root,target)
    for name in dirs+files:
        rel=os.path.normpath(os.path.join(relroot,name)); src=os.path.join(source,rel); dst=os.path.join(target,rel)
        if not os.path.lexists(src): raise SystemExit(1)
        sm,dm=os.lstat(src).st_mode,os.lstat(dst).st_mode
        if not ((stat.S_ISREG(sm) and stat.S_ISREG(dm)) or (stat.S_ISDIR(sm) and stat.S_ISDIR(dm))): raise SystemExit(1)
PY
}
tree_has_only_managed_paths() {
  local source=$1 target=$2 state=$3
  [[ -d $target && ! -L $target && -f $state ]] || return 1
  python3 - "$source" "$target" "$state" <<'PY'
import os,stat,sys
source,target,state=map(os.path.abspath,sys.argv[1:])
managed=set()
with open(state,encoding="utf-8") as stream:
    for line in stream:
        fields=line.rstrip("\n").split("\t")
        if len(fields)==4 and fields[0]=="dirfile" and fields[1]==target:
            managed.add(os.path.normpath(fields[2]))
for root,dirs,files in os.walk(target,followlinks=False):
    relroot=os.path.relpath(root,target)
    for name in dirs+files:
        rel=os.path.normpath(os.path.join(relroot,name)); src=os.path.join(source,rel); dst=os.path.join(target,rel)
        dm=os.lstat(dst).st_mode
        if stat.S_ISLNK(dm) or not (stat.S_ISREG(dm) or stat.S_ISDIR(dm)): raise SystemExit(1)
        if stat.S_ISREG(dm) and rel not in managed and not (os.path.isfile(src) and not os.path.islink(src)): raise SystemExit(1)
PY
}
record_tree_inventory() { local source=$1 target=$2 file relative; while IFS= read -r -d '' file; do relative=${file#"$source/"}; record_tree_file "$target" "$relative" "$(sha256_file "$file")"; done < <(filtered_files "$source" | sort -z); }
preflight_tree() {
  local source=$1 target=$2 canonical
  canonical=$(canonical_path "$source"); validate_source_tree "$canonical"; target_parent_is_safe '' "$target" || die
  if [[ -e $target || -L $target ]]; then same_physical_path "$canonical" "$target" && die; fi
  [[ ! -L $target ]] || die
  if [[ -d $target ]]; then state_directory_is_managed "${STATE:-}" "$target" || die; tree_has_only_managed_paths "$canonical" "$target" "${STATE:-}" || die
  elif [[ -e $target ]]; then die; fi
}
install_tree() {
  local source=$1 target=$2 canonical actual expected
  canonical=$(canonical_path "$source"); preflight_tree "$canonical" "$target"; INSTALL_RESULT=changed; expected=$(sha256_tree "$canonical")
  if [[ -d $target ]]; then actual=$(sha256_tree "$target"); if [[ $actual == "$expected" ]]; then INSTALL_RESULT=unchanged; record_target dircopy "$target" "$expected"; record_tree_inventory "$canonical" "$target"; return; fi; [[ $DRY_RUN == true ]] || rm -rf -- "$target"; fi
  [[ $DRY_RUN == true ]] || copy_filtered_tree "$canonical" "$target"
  record_target dircopy "$target" "$expected"; record_tree_inventory "$canonical" "$target"
}
install_file() {
  local source=$1 target=$2
  preflight_file "$source" "$target"; INSTALL_RESULT=changed
  if [[ -e $target ]]; then
    same_physical_path "$source" "$target" && die
    if [[ -f $target && ! -L $target ]] && cmp -s "$source" "$target"; then INSTALL_RESULT=unchanged; record_target copy "$target" "$(sha256_file "$source")"; return; fi
    state_target_is_managed "${STATE:-}" "$target" || die
    [[ $DRY_RUN == true ]] || rm -f -- "$target"
  fi
  if [[ $DRY_RUN == false ]]; then mkdir -p "$(dirname "$target")"; cp "$source" "$target"; fi
  record_target copy "$target" "$(sha256_file "$source")"
}
relative_managed_path_is_safe() { local relative=$1; [[ -n $relative && $relative != /* && $relative != . && $relative != .. && $relative != ../* && $relative != */../* && $relative != */.. && $relative != *$'\t'* && $relative != *$'\n'* && $relative != *'//'* ]]; }
managed_file_matches() {
  local root=$1 relative=$2 expected=$3 current component parent
  parent=${relative%/*}; relative_managed_path_is_safe "$relative" || return 1; [[ -d $root && ! -L $root ]] || return 1; current=$root
  if [[ $parent != "$relative" ]]; then local IFS=/; read -r -a parts <<< "$parent"; for component in "${parts[@]}"; do current="$current/$component"; [[ -d $current && ! -L $current ]] || return 1; done; fi
  current="$root/$relative"; [[ -f $current && ! -L $current && $(sha256_file "$current") == "$expected" ]]
}
state_has_tree_inventory() { local state=$1 selected=$2 kind target rest; [[ -f $state ]] || return 1; while IFS=$'\t' read -r kind target rest; do [[ $kind == dirfile && $target == "$selected" ]] && return 0; done < "$state"; return 1; }
directory_removal_status() {
  local state=$1 selected=$2 source=${3:-} kind target relative expected found=false removable=false changed=false
  [[ -f $state ]] || { printf 'absent\n'; return; }; target_parent_is_safe '' "$selected" || { printf 'preserved\n'; return; }
  [[ ! -L $selected ]] || { printf 'preserved\n'; return; }; [[ -e $selected ]] || { printf 'absent\n'; return; }; [[ -d $selected ]] || { printf 'preserved\n'; return; }
  [[ -z $source ]] || ! same_physical_path "$source" "$selected" || { printf 'preserved\n'; return; }
  state_has_tree_inventory "$state" "$selected" || { printf 'preserved\n'; return; }
  while IFS=$'\t' read -r kind target relative expected; do [[ $kind == dirfile && $target == "$selected" ]] || continue; found=true; if managed_file_matches "$selected" "$relative" "$expected"; then removable=true; else changed=true; fi; done < "$state"
  [[ $found == true ]] || { printf 'preserved\n'; return; }
  if [[ $changed == false ]] && tree_has_only_source_paths "${source:-$selected}" "$selected"; then printf 'changed\n'; elif [[ $removable == true ]]; then printf 'partial\n'; else printf 'preserved\n'; fi
}
remove_recorded_directory() {
  local state=$1 selected=$2 source=${3:-} status kind target relative expected parent
  status=$(directory_removal_status "$state" "$selected" "$source")
  [[ $status == changed || $status == partial ]] || return 0
  [[ $DRY_RUN == true ]] && return 0
  while IFS=$'\t' read -r kind target relative expected; do [[ $kind == dirfile && $target == "$selected" ]] || continue; managed_file_matches "$selected" "$relative" "$expected" && rm -- "$selected/$relative"; done < "$state"
  while IFS=$'\t' read -r kind target relative expected; do
    [[ $kind == dirfile && $target == "$selected" ]] || continue
    parent=${relative%/*}; [[ $parent != "$relative" ]] || continue
    while [[ -n $parent && $parent != . ]]; do rmdir -- "$selected/$parent" 2>/dev/null || true; [[ $parent == */* ]] || break; parent=${parent%/*}; done
  done < "$state"
  rmdir -- "$selected" 2>/dev/null || true
}
path_is_below() { local path root; path=$(realpath -m -- "$1"); root=$(realpath -m -- "$2"); [[ $path == "$root/"* ]]; }
reconcile_stale_targets() {
  local old=$1 new=$2; shift 2; local kind target expected status root allowed
  [[ -f $old ]] || return 0
  while IFS=$'\t' read -r kind target expected; do
    [[ $kind == copy || $kind == dircopy ]] || continue
    awk -F '\t' -v selected="$target" '$2 == selected {found=1} END {exit !found}' "$new" && continue
    allowed=false; for root in "$@"; do path_is_below "$target" "$root" && allowed=true; done; [[ $allowed == true ]] || continue
    if [[ $kind == copy ]]; then if [[ -f $target && ! -L $target && $(sha256_file "$target") == "$expected" ]]; then STALE_CHANGED=true; [[ $DRY_RUN == true ]] || rm -- "$target"; fi
    else status=$(directory_removal_status "$old" "$target"); if [[ $status == changed || $status == partial ]]; then STALE_CHANGED=true; remove_recorded_directory "$old" "$target"; fi; fi
  done < "$old"
}
remove_recorded_targets() {
  local state=$1; shift; local kind target expected actual root allowed status
  [[ -f $state ]] || return 0
  while IFS=$'\t' read -r kind target expected; do
    [[ $kind == copy || $kind == dircopy ]] || continue; allowed=false; for root in "$@"; do path_is_below "$target" "$root" && allowed=true; done; [[ $allowed == true ]] || { REMOVE_PRESERVED=true; continue; }
    if [[ $kind == copy ]]; then if [[ -f $target && ! -L $target ]]; then actual=$(sha256_file "$target"); if [[ $actual == "$expected" ]]; then REMOVE_CHANGED=true; [[ $DRY_RUN == true ]] || rm -- "$target"; else REMOVE_PRESERVED=true; fi; elif [[ -e $target || -L $target ]]; then REMOVE_PRESERVED=true; fi
    else status=$(directory_removal_status "$state" "$target"); case $status in changed|partial) REMOVE_CHANGED=true; remove_recorded_directory "$state" "$target" ;; preserved) REMOVE_PRESERVED=true ;; esac; fi
  done < "$state"
}
prune_dir() { [[ $DRY_RUN == true ]] && return 0; target_parent_is_safe '' "$1" || return 0; [[ -d $1 && ! -L $1 ]] || return 0; rmdir -- "$1" 2>/dev/null || true; }

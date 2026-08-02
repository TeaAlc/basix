#!/usr/bin/env bash
# REPORT_POINT is consumed by die() from the sourced reporting library.
# shellcheck disable=SC2034
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Resolved from this bundle's absolute runtime root.
# shellcheck disable=SC1091
source "$ROOT/setup/lib/common.sh"
MODE='' DRY_RUN=false FORCE=false UNINSTALL=false TARGET='' INSTALL_LUMEN=yes LUMEN_INDEX=ask
while (($#)); do
  case $1 in
    --mode) (($# >= 2)) || die '--mode requires a value'; MODE=$2; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    --install-lumen) (($# >= 2)) || die '--install-lumen requires yes or no'; INSTALL_LUMEN=$2; shift 2 ;;
    --lumen-index) (($# >= 2)) || die '--lumen-index requires ask, yes, or no'; LUMEN_INDEX=$2; shift 2 ;;
    --uninstall) UNINSTALL=true; shift ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z $TARGET ]] || die 'only one TARGET is allowed'; TARGET=$1; shift ;;
  esac
done
[[ -n $TARGET ]] || TARGET=.
require_yes_no --install-lumen "$INSTALL_LUMEN"
[[ $LUMEN_INDEX == ask || $LUMEN_INDEX == yes || $LUMEN_INDEX == no ]] || die "invalid --lumen-index value: $LUMEN_INDEX (expected ask, yes, or no)"
if [[ -e $TARGET && ! -d $TARGET ]]; then die "TARGET is not a directory: $TARGET"; fi
TARGET=$(realpath -m -- "$TARGET")
INSTALL_TARGET_ROOT=$TARGET
PROJECT_DEFAULT_MODE='link'
ROOT_CANONICAL=$(realpath -e -- "$ROOT") || die "cannot resolve installer root: $ROOT"
if [[ $(realpath -m -- "$TARGET") == "$(dirname "$ROOT_CANONICAL")" ]]; then
  PROJECT_DEFAULT_MODE=copy
fi
if [[ $UNINSTALL == false && -z $MODE ]]; then
  choose_mode "$PROJECT_DEFAULT_MODE"
fi
[[ $UNINSTALL == true && -z $MODE ]] || require_mode "$MODE"
CONFIG="$TARGET/.codex/config.toml"
STATE="$TARGET/.codex/.basix-install-state"
HELPER="$ROOT/setup/lib/manage_developer_instructions.py"
INSTRUCTIONS="$ROOT/setup/developer_instruction.md"

report_header
report_meta Target "$TARGET"
report_meta Mode "$([[ $UNINSTALL == true ]] && printf uninstall || printf '%s' "$MODE")"
report_meta 'Dry run' "$DRY_RUN"

restore_directory_links() {
  local state=$1 kind target encoded link_text resolved
  [[ -f $state ]] || return 0
  while IFS=$'\t' read -r kind target encoded; do
    [[ $kind == restore-dirlink ]] || continue
    link_text=${encoded%%|*}; resolved=${encoded#*|}
    path_is_within_any "$target" "$TARGET/.codex/agents" "$TARGET/.agents/skills" || { orange_warning "Preserving out-of-scope directory-link state path: $target"; continue; }
    target_parent_is_safe '' "$target" || { orange_warning "Not restoring target below foreign directory link: $target"; continue; }
    [[ -n ${STATE_TMP:-} ]] && record_target restore-dirlink "$target" "$encoded"
    if [[ -L $target && $(readlink "$target") == "$link_text" ]]; then continue; fi
    if [[ -d $target && ! -L $target && $DRY_RUN == false ]]; then
      find "$target" -depth -mindepth 1 -type d -empty -delete
    fi
    if [[ -d $target && ! -L $target ]] && [[ -z $(find "$target" -mindepth 1 -print -quit) ]]; then
      if [[ $DRY_RUN == true ]]; then note "Would restore directory link $target -> $link_text"; else note "Restoring directory link $target -> $link_text"; fi
      if [[ $DRY_RUN == false ]]; then rmdir "$target"; ln -s "$link_text" "$target"; fi
    elif [[ -e $target || -L $target ]]; then
      orange_warning "Not restoring changed directory link target: $target (was $link_text -> $resolved)"
    fi
  done < "$state"
}

migrate_legacy_bundle() {
  local kind target expected actual source relative legacy="$TARGET/.basix"
  [[ -f $STATE ]] || return 0
  while IFS=$'\t' read -r kind target expected; do
    [[ $target == "$legacy" ]] || continue
    case $kind in
      bundle-link)
        if [[ -L $legacy && $(readlink "$legacy") == "$expected" ]]; then
          [[ $DRY_RUN == true ]] || rm -- "$legacy"
        elif [[ -e $legacy || -L $legacy ]]; then
          orange_warning "Preserving changed legacy bundle: $legacy"
        fi
        ;;
      bundle-copy)
        [[ -d $legacy && ! -L $legacy ]] || continue
        actual=$(sha256_tree "$legacy")
        if [[ $actual == "$expected" ]]; then
          [[ $DRY_RUN == true ]] || rm -rf -- "$legacy"
          continue
        fi
        # A legacy bundle may now contain project-owned files. Remove only
        # recognizable, unchanged installer payload and leave everything else.
        while IFS= read -r -d '' source; do
          relative=${source#"$ROOT/"}
          target="$legacy/$relative"
          if [[ -f $target && ! -L $target ]] && cmp -s "$source" "$target"; then
            [[ $DRY_RUN == true ]] || rm -- "$target"
          elif [[ -L $target && $(readlink "$target") == "$source" ]]; then
            [[ $DRY_RUN == true ]] || rm -- "$target"
          fi
        done < <(filtered_project_files "$ROOT" | sort -z)
        if [[ $DRY_RUN == false ]]; then
          # The legacy bundle copy deliberately excludes Python cache artifacts
          # from its manifest. Remove only cache paths that map to directories in
          # the canonical source tree; leave foreign/project-owned caches intact.
          while IFS= read -r -d '' source; do
            relative=${source#"$legacy/"}
            [[ $relative == plugin/* ]] && continue
            source_dir="$ROOT/${relative%/*}"
            [[ -d $source_dir ]] || continue
            rm -- "$source"
          done < <(find "$legacy" -type f \( -name '*.pyc' -o -name '*.pyo' \) -print0)
          while IFS= read -r -d '' source; do
            relative=${source#"$legacy/"}
            [[ $relative == plugin/* ]] && continue
            source_dir="$ROOT/${relative%/__pycache__}"
            [[ -d $source_dir ]] || continue
            rm -rf -- "$source"
          done < <(find "$legacy" -type d -name __pycache__ -print0)
          find "$legacy" -depth -mindepth 1 -type d -empty -delete
          rmdir "$legacy" 2>/dev/null || true
        fi
        ;;
    esac
  done < "$STATE"
}

prepare_copy_directory() {
  local target=$1 expected_source=$2 text resolved
  target_parent_is_safe "$expected_source" "$target" || die "foreign directory link protected: $(dirname "$target")"
  if [[ -L $target ]]; then
    text=$(readlink "$target")
    if state_has_directory_link "$STATE" "$target"; then
      while IFS=$'\t' read -r kind saved encoded; do
        [[ $kind == restore-dirlink && $saved == "$target" ]] && record_target "$kind" "$saved" "$encoded"
      done < "$STATE"
    else
      resolved=$(realpath -e -- "$target" 2>/dev/null) || die "cannot resolve foreign directory link (possible symlink loop): $target"
      [[ $resolved == "$(canonical_path "$expected_source")" ]] || die "foreign directory link protected: $target -> $text"
      record_target restore-dirlink "$target" "$text|$resolved"
    fi
    if [[ $DRY_RUN == true ]]; then note "Would replace managed source directory link with copies: $target"; else note "Replacing managed source directory link with copies: $target"; fi
    [[ $DRY_RUN == true ]] || rm -- "$target"
  elif [[ -f $STATE ]]; then
    while IFS=$'\t' read -r kind saved encoded; do
      [[ $kind == restore-dirlink && $saved == "$target" ]] && record_target "$kind" "$saved" "$encoded"
    done < "$STATE"
  fi
  return 0
}

prepare_link_directory() {
  local target=$1 expected_source=$2 resolved expected
  target_parent_is_safe "$expected_source" "$target" || die "foreign directory link protected: $(dirname "$target")"
  [[ -L $target ]] || return 0
  expected=$(canonical_path "$expected_source")
  resolved=$(realpath -e -- "$target" 2>/dev/null) || resolved=''
  [[ $resolved == "$expected" ]] && return 0
  if state_has_directory_link "$STATE" "$target"; then
    if [[ $DRY_RUN == true ]]; then note "Would detach changed managed directory link: $target"; else note "Detaching changed managed directory link: $target"; fi
    if [[ $DRY_RUN == false ]]; then rm -- "$target"; mkdir -p "$target"; fi
    return 0
  fi
  [[ -n $resolved ]] || die "cannot resolve foreign directory link (possible symlink loop): $target"
  die "foreign directory link protected: $target -> $(readlink "$target")"
}

if [[ $UNINSTALL == true ]]; then
  report_group 'Developer Instructions'
  helper_args=(remove --config "$CONFIG" --remove-empty-file --status-json)
  [[ $DRY_RUN == false ]] || helper_args+=(--dry-run)
  REPORT_POINT='Developer instructions'; helper_json=$(python3 "$HELPER" "${helper_args[@]}") || die
  helper_status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$helper_json")
  report_point "$helper_status" 'Developer instructions' "$([[ $DRY_RUN == true && $helper_status == changed ]] && printf 'Would remove' || printf '%s' "$([[ $helper_status == changed ]] && printf Removed || printf 'Not present')")"
  migrate_legacy_bundle
  report_group 'Skills'
  declare -A remove_skill_changed=() remove_skill_preserved=() remove_skill_total=()
  while IFS= read -r -d '' source; do
    relative=${source#"$ROOT/skills/"}; skill=${relative%%/*}; target="$TARGET/.agents/skills/$relative"
    remove_skill_total[$skill]=$((${remove_skill_total[$skill]:-0} + 1))
    removal=$(recorded_removal_status "$STATE" "$target")
    [[ $removal != changed ]] || remove_skill_changed[$skill]=$((${remove_skill_changed[$skill]:-0} + 1))
    [[ $removal != preserved ]] || remove_skill_preserved[$skill]=$((${remove_skill_preserved[$skill]:-0} + 1))
  done < <(filtered_files "$ROOT/skills" | sort -z)
  while IFS= read -r skill; do
    total=${remove_skill_total[$skill]}; changed=${remove_skill_changed[$skill]:-0}; preserved=${remove_skill_preserved[$skill]:-0}
    if ((changed)); then
      detail="$changed of $total files $([[ $DRY_RUN == true ]] && printf 'would be removed' || printf removed)"
      ((preserved == 0)) || detail+=", $preserved preserved"
      report_point changed "$skill" "$detail"
    elif ((preserved)); then report_point unchanged "$skill" "$preserved of $total files preserved"
    else report_point unchanged "$skill" 'Not installed'; fi
  done < <(printf '%s\n' "${!remove_skill_total[@]}" | sort)
  report_group 'Agents'
  while IFS= read -r -d '' source; do
    name=$(basename "$source" .toml); target="$TARGET/.codex/agents/$(basename "$source")"; removal=$(recorded_removal_status "$STATE" "$target")
    case $removal in changed) report_point changed "$name" "$([[ $DRY_RUN == true ]] && printf 'Would remove' || printf Removed)" ;; preserved) report_point unchanged "$name" 'Preserved local changes' ;; absent) report_point unchanged "$name" 'Not installed' ;; esac
  done < <(find "$ROOT/agents/native" -maxdepth 1 -type f -name '*.toml' -print0 | sort -z)
  REMOVE_CHANGED=false REMOVE_PRESERVED=false
  remove_recorded_targets "$STATE" "$TARGET/.codex/agents" "$TARGET/.agents/skills"
  restore_directory_links "$STATE"
  [[ $DRY_RUN == true ]] || rm -f "$STATE"
  while IFS= read -r -d '' source_dir; do
    relative_dir=${source_dir#"$ROOT/skills"}
    prune_dir "$TARGET/.agents/skills$relative_dir"
  done < <(find "$ROOT/skills" -depth -type d -print0 | sort -zr)
  prune_dir "$TARGET/.agents/skills"; prune_dir "$TARGET/.agents"
  prune_dir "$TARGET/.codex/agents"; prune_dir "$TARGET/.codex"
  report_group 'Lumen'; report_point unchanged 'Lumen integration' 'Preserved'
  report_result
  exit 0
fi

REPORT_POINT='Codex CLI'; command -v codex >/dev/null || die
validate_source_tree "$ROOT/agents/native"
validate_source_tree "$ROOT/skills"
REPORT_POINT='Target parents'
while IFS= read -r -d '' source; do
  relative=${source#"$ROOT/skills/"}
  skill=${relative%%/*}; skill_root="$TARGET/.agents/skills/$skill"
  if ! state_has_directory_link "$STATE" "$skill_root"; then
    manifest_target_is_safe "$source" "$TARGET/.agents/skills/$relative" || die "foreign directory link or directory target protected: $TARGET/.agents/skills/$relative"
  fi
done < <(filtered_files "$ROOT/skills" | sort -z)
while IFS= read -r -d '' source; do
  agent_root="$TARGET/.codex/agents"
  if ! state_has_directory_link "$STATE" "$agent_root"; then
    manifest_target_is_safe "$source" "$agent_root/$(basename "$source")" || die "foreign directory link or directory target protected: $agent_root/$(basename "$source")"
  fi
done < <(find -L "$ROOT/agents/native" -maxdepth 1 -type f -name '*.toml' -print0 | sort -z)
LUMEN_INSTALL_RESULT=unchanged
if [[ $INSTALL_LUMEN == yes ]] && ! lumen_mcp_installed; then
  lumen_args=()
  [[ $DRY_RUN == false ]] || lumen_args+=(--dry-run)
  [[ $FORCE == false ]] || lumen_args+=(--force)
  REPORT_POINT='Lumen integration'; "$ROOT/setup/install_ory_lumen.sh" "${lumen_args[@]}" >/dev/null || die
  LUMEN_INSTALL_RESULT=changed
fi

STATE_TMP=$(mktemp)
trap 'rm -f "$STATE_TMP"' EXIT
migrate_legacy_bundle
if [[ $MODE == link && -f $STATE ]]; then
  # A mode switch may have replaced canonical source-directory links with
  # managed copies. Remove only unchanged managed objects, then restore those
  # links before installing direct source links.
  remove_recorded_targets "$STATE" "$TARGET/.codex/agents" "$TARGET/.agents/skills"
  restore_directory_links "$STATE"
fi
if [[ $MODE == copy ]]; then
  REPORT_POINT='Skills and agent directories'
  prepare_copy_directory "$TARGET/.codex/agents" "$ROOT/agents/native"
  while IFS= read -r -d '' skill_source; do
    prepare_copy_directory "$TARGET/.agents/skills/$(basename "$skill_source")" "$skill_source"
  done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
else
  REPORT_POINT='Skills and agent directories'
  prepare_link_directory "$TARGET/.codex/agents" "$ROOT/agents/native"
  while IFS= read -r -d '' skill_source; do
    prepare_link_directory "$TARGET/.agents/skills/$(basename "$skill_source")" "$skill_source"
  done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
fi
report_group 'Skills'
declare -A skill_changed=() skill_total=()
while IFS= read -r -d '' source; do
  relative=${source#"$ROOT/skills/"}
  skill=${relative%%/*}; REPORT_POINT="Skill: $skill"
  install_file "$source" "$TARGET/.agents/skills/$relative"
  skill_total[$skill]=$((${skill_total[$skill]:-0} + 1))
  [[ $INSTALL_RESULT == unchanged ]] || skill_changed[$skill]=$((${skill_changed[$skill]:-0} + 1))
done < <(filtered_files "$ROOT/skills" | sort -z)
while IFS= read -r skill; do
  changed=${skill_changed[$skill]:-0}; total=${skill_total[$skill]}
  status=unchanged; detail="$total files current"
  if ((changed)); then status=changed; detail="$changed of $total files $([[ $DRY_RUN == true ]] && printf 'would change' || printf changed)"; fi
  report_point "$status" "$skill" "$detail"
done < <(printf '%s\n' "${!skill_total[@]}" | sort)
report_group 'Agents'
while IFS= read -r -d '' source; do
  name=$(basename "$source" .toml); REPORT_POINT="Agent: $name"
  install_file "$source" "$TARGET/.codex/agents/$(basename "$source")"
  report_point "$INSTALL_RESULT" "$name" "$([[ $DRY_RUN == true && $INSTALL_RESULT == changed ]] && printf 'Would install' || printf '%s' "$([[ $INSTALL_RESULT == changed ]] && printf Installed || printf Current)")"
done < <(find -L "$ROOT/agents/native" -maxdepth 1 -type f -name '*.toml' -print0 | sort -z)
STALE_CHANGED=false
reconcile_stale_targets "$STATE" "$STATE_TMP" "$TARGET/.codex/agents" "$TARGET/.agents/skills"
report_point "$([[ $STALE_CHANGED == true ]] && printf changed || printf unchanged)" 'Stale cleanup' "$([[ $STALE_CHANGED == true ]] && printf Reconciled || printf 'Nothing stale')"
report_group 'Developer Instructions'
helper_args=(add --config "$CONFIG" --instructions "$INSTRUCTIONS" --status-json)
[[ $DRY_RUN == false ]] || helper_args+=(--dry-run)
REPORT_POINT='Developer instructions'; helper_json=$(python3 "$HELPER" "${helper_args[@]}") || die
helper_status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$helper_json")
report_point "$helper_status" 'Developer instructions' "$([[ $DRY_RUN == true && $helper_status == changed ]] && printf 'Would update' || printf '%s' "$([[ $helper_status == changed ]] && printf Updated || printf Current)")"
if [[ $DRY_RUN == false ]]; then mkdir -p "$(dirname "$STATE")"; mv "$STATE_TMP" "$STATE"; fi

report_group 'Lumen'
if [[ $INSTALL_LUMEN == no ]]; then
  report_point unchanged 'Lumen integration' 'Skipped'
elif [[ $LUMEN_INSTALL_RESULT == changed ]]; then
  report_point changed 'Lumen integration' "$([[ $DRY_RUN == true ]] && printf 'Would install' || printf Installed)"
else
  report_point unchanged 'Lumen integration' 'Enabled'
fi
if lumen_mcp_installed; then
  run_index=$LUMEN_INDEX
  if [[ $run_index == ask ]]; then
    run_index=no
    if [[ -t 0 ]]; then
      printf 'Run "lumen index ." in %s now? [y/N] ' "$TARGET"
      read -r answer
      [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]] && run_index=yes
    fi
  fi
  if [[ $run_index == yes ]]; then
    if [[ $DRY_RUN == true ]]; then
      report_point changed 'Project index' 'Would run lumen index .'
    elif launcher=$(lumen_launcher); then
      REPORT_POINT='Project index'; (cd "$TARGET" && "$launcher" index .) || die
      report_point changed 'Project index' 'Indexed'
    else
      REPORT_POINT='Project index'; die
    fi
  else
    report_point unchanged 'Project index' 'Skipped'
  fi
else
  if [[ $LUMEN_INDEX == yes ]]; then REPORT_POINT='Project index'; die; fi
  report_point unchanged 'Project index' "$([[ $INSTALL_LUMEN == no ]] && printf Skipped || printf Unavailable)"
fi
report_result

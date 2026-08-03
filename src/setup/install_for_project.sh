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
AGENT_DIR="$TARGET/.codex/basix/agents"
HELPER="$ROOT/setup/lib/manage_developer_instructions.py"
INSTRUCTIONS="$ROOT/setup/developer_instruction.md"

report_header
report_meta Target "$TARGET"
report_meta Mode "$([[ $UNINSTALL == true ]] && printf uninstall || printf '%s' "$MODE")"
report_meta 'Dry run' "$DRY_RUN"
REPORT_POINT='Configuration parents'
target_parent_is_safe '' "$CONFIG" || die "foreign configuration parent protected: $CONFIG"
target_parent_is_safe '' "$STATE" || die "foreign state parent protected: $STATE"
[[ ! -L $CONFIG && ! -L $STATE ]] || die 'linked configuration or installer state protected'

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
  report_group 'Agent configuration'
  helper_args=(agent-remove --config "$CONFIG" --agents-source "$ROOT/agents/native" --agents-dir "$AGENT_DIR" --remove-empty-file --status-json)
  [[ $DRY_RUN == false ]] || helper_args+=(--dry-run)
  REPORT_POINT='Agent configuration'; helper_json=$(python3 "$HELPER" "${helper_args[@]}") || die
  agent_config_status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$helper_json")
  case $agent_config_status in
    changed) report_point changed 'Agent configuration' "$([[ $DRY_RUN == true ]] && printf 'Would remove' || printf Removed)" ;;
    preserved) report_point unchanged 'Agent configuration' 'Preserved local changes and agent payload' ;;
    *) report_point unchanged 'Agent configuration' 'Not present' ;;
  esac
  report_group 'Developer Instructions'
  helper_args=(remove --config "$CONFIG" --remove-empty-file --status-json)
  [[ $DRY_RUN == false ]] || helper_args+=(--dry-run)
  REPORT_POINT='Developer instructions'; helper_json=$(python3 "$HELPER" "${helper_args[@]}") || die
  helper_status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$helper_json")
  report_point "$helper_status" 'Developer instructions' "$([[ $DRY_RUN == true && $helper_status == changed ]] && printf 'Would remove' || printf '%s' "$([[ $helper_status == changed ]] && printf Removed || printf 'Not present')")"
  migrate_legacy_bundle
  report_group 'Skills'
  REMOVE_CHANGED=false REMOVE_PRESERVED=false REMOVE_PROCESSED_DIRECTORIES=''
  while IFS= read -r -d '' source; do
    skill=$(basename "$source"); target="$TARGET/.agents/skills/$skill"
    total=$(filtered_files "$source" | tr -cd '\0' | wc -c); removal=$(directory_removal_status "$STATE" "$target" "$source")
    case $removal in
      changed) report_point changed "$skill" "$total files $([[ $DRY_RUN == true ]] && printf 'would be removed' || printf removed)" ;;
      partial) report_point changed "$skill" "$([[ $DRY_RUN == true ]] && printf 'Would remove unchanged files; preserve foreign or changed content' || printf 'Removed unchanged files; preserved foreign or changed content')" ;;
      preserved) REMOVE_PRESERVED=true; report_point unchanged "$skill" 'Preserved local changes' ;;
      absent) report_point unchanged "$skill" 'Not installed' ;;
    esac
    remove_recorded_directory "$STATE" "$target" "$source"
    if [[ $removal == partial && ( -e $target || -L $target ) ]]; then REMOVE_PRESERVED=true; fi
    mark_processed_directory "$target"
  done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
  report_group 'Agents'
  agent_removal=$(directory_removal_status "$STATE" "$AGENT_DIR" "$ROOT/agents/native")
  [[ $agent_removal == preserved || $agent_config_status == preserved ]] && REMOVE_PRESERVED=true
  while IFS= read -r -d '' source; do
    name=$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1], "rb"))["name"])' "$source")
    if [[ $agent_config_status == preserved ]]; then removal=preserved; else removal=$agent_removal; fi
    case $removal in changed) report_point changed "$name" "$([[ $DRY_RUN == true ]] && printf 'Would remove' || printf Removed)" ;; partial) report_point changed "$name" "$([[ $DRY_RUN == true ]] && printf 'Would remove unchanged files; preserve local changes' || printf 'Removed unchanged files; preserved local changes')" ;; preserved) report_point unchanged "$name" 'Preserved with configuration' ;; absent) report_point unchanged "$name" 'Not installed' ;; esac
  done < <(find "$ROOT/agents/native" -maxdepth 1 -type f -name '*.toml' -print0 | sort -z)
  [[ $agent_config_status == preserved ]] || remove_recorded_directory "$STATE" "$AGENT_DIR" "$ROOT/agents/native"
  if [[ $agent_removal == partial && ( -e $AGENT_DIR || -L $AGENT_DIR ) ]]; then REMOVE_PRESERVED=true; fi
  mark_processed_directory "$AGENT_DIR"
  REMOVE_EXCLUDED_TARGET=$AGENT_DIR
  remove_recorded_targets "$STATE" "$TARGET/.codex/agents" "$TARGET/.agents/skills" "$TARGET/.codex/basix"
  unset REMOVE_EXCLUDED_TARGET REMOVE_PROCESSED_DIRECTORIES
  prune_dir "$TARGET/.agents/skills"; prune_dir "$TARGET/.agents"
  prune_dir "$TARGET/.codex/agents"; prune_dir "$TARGET/.codex/basix"; prune_dir "$TARGET/.codex"
  [[ -e $TARGET/.agents/skills || -e $TARGET/.codex/basix ]] && REMOVE_PRESERVED=true
  if [[ $DRY_RUN == false && $agent_config_status != preserved && $REMOVE_PRESERVED == false ]]; then rm -f "$STATE"; fi
  prune_dir "$TARGET/.codex"
  report_group 'Lumen'; report_point unchanged 'Lumen integration' 'Preserved'
  report_result
  exit 0
fi

REPORT_POINT='Codex CLI'; command -v codex >/dev/null || die
validate_source_tree "$ROOT/agents/native"
validate_source_tree "$ROOT/skills"
REPORT_POINT='Agent configuration conflicts'
python3 "$HELPER" agent-check --config "$CONFIG" --agents-source "$ROOT/agents/native" --agents-dir "$AGENT_DIR" --status-json >/dev/null || die
REPORT_POINT='Managed directories'
while IFS= read -r -d '' source; do
  preflight_tree "$source" "$TARGET/.agents/skills/$(basename "$source")"
done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
preflight_tree "$ROOT/agents/native" "$AGENT_DIR"
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
migrate_shared_agent_files "$STATE" "$TARGET/.codex/agents" "$ROOT/agents/native"
report_group 'Skills'
while IFS= read -r -d '' source; do
  skill=$(basename "$source"); REPORT_POINT="Skill: $skill"
  install_tree "$source" "$TARGET/.agents/skills/$skill"
  total=$(filtered_files "$source" | tr -cd '\0' | wc -c)
  report_point "$INSTALL_RESULT" "$skill" "$total files $([[ $INSTALL_RESULT == changed ]] && printf '%s' "$([[ $DRY_RUN == true ]] && printf 'would change' || printf changed)" || printf current)"
done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
report_group 'Agents'
REPORT_POINT='Private agent directory'; install_tree "$ROOT/agents/native" "$AGENT_DIR"; agent_install_result=$INSTALL_RESULT
while IFS= read -r -d '' source; do
  name=$(python3 -c 'import sys,tomllib; print(tomllib.load(open(sys.argv[1], "rb"))["name"])' "$source")
  report_point "$agent_install_result" "$name" "$([[ $DRY_RUN == true && $agent_install_result == changed ]] && printf 'Would install' || printf '%s' "$([[ $agent_install_result == changed ]] && printf Installed || printf Current)")"
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
report_group 'Agent configuration'
helper_args=(agent-add --config "$CONFIG" --agents-source "$ROOT/agents/native" --agents-dir "$AGENT_DIR" --status-json)
[[ $DRY_RUN == false ]] || helper_args+=(--dry-run)
REPORT_POINT='Agent configuration'; helper_json=$(python3 "$HELPER" "${helper_args[@]}") || die
helper_status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$helper_json")
report_point "$helper_status" 'Agent configuration' "$([[ $DRY_RUN == true && $helper_status == changed ]] && printf 'Would update' || printf '%s' "$([[ $helper_status == changed ]] && printf Updated || printf Current)")"
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

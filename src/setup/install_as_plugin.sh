#!/usr/bin/env bash
# REPORT_POINT is consumed by die() from the sourced reporting library.
# shellcheck disable=SC2034
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/setup/lib/common.sh"
MODE='' DRY_RUN=false FORCE=false UNINSTALL=false INSTALL_LUMEN=yes
while (($#)); do
  case $1 in
    --mode) (($# >= 2)) || die; MODE=$2; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    --install-lumen) (($# >= 2)) || die; INSTALL_LUMEN=$2; shift 2 ;;
    --uninstall) UNINSTALL=true; shift ;;
    *) die ;;
  esac
done
if [[ $UNINSTALL == false && -z $MODE ]]; then choose_mode link; fi
[[ $UNINSTALL == true && -z $MODE ]] || require_mode "$MODE"
require_yes_no --install-lumen "$INSTALL_LUMEN"
CODEX_HOME=${CODEX_HOME:-${HOME:?}/.codex}
CONFIG="$CODEX_HOME/config.toml" STATE="$CODEX_HOME/.basix-install-state"
HELPER="$ROOT/setup/lib/manage_developer_instructions.py" INSTRUCTIONS="$ROOT/setup/developer_instruction.md"
LEGACY_PROFILE="$CODEX_HOME/basix-luna-researcher.config.toml"
PLUGIN_ROOT="$CODEX_HOME/basix-plugin-root"
INSTALL_TARGET_ROOT="$CODEX_HOME"

report_header
report_meta Target "$CODEX_HOME"
report_meta Mode "$([[ $UNINSTALL == true ]] && printf uninstall || printf '%s' "$MODE")"
report_meta 'Dry run' "$DRY_RUN"
command -v codex >/dev/null || { REPORT_POINT='Codex CLI'; die; }

if [[ $UNINSTALL == true ]]; then
  report_group 'Marketplace / Plugin'
  if plugin_registered; then
    if [[ $DRY_RUN == false ]]; then REPORT_POINT='Plugin'; codex plugin remove basix@basix-local --json >/dev/null 2>&1 || die; fi
    report_point changed 'Plugin' "$([[ $DRY_RUN == true ]] && printf 'Would remove' || printf Removed)"
  else report_point unchanged 'Plugin' 'Not installed'; fi
  if marketplace_registered; then
    if [[ $DRY_RUN == false ]]; then REPORT_POINT='Marketplace'; codex plugin marketplace remove basix-local --json >/dev/null 2>&1 || die; fi
    report_point changed 'Marketplace' "$([[ $DRY_RUN == true ]] && printf 'Would remove' || printf Removed)"
  else report_point unchanged 'Marketplace' 'Not registered'; fi
  report_group 'Developer Instructions'
  helper_args=(remove --config "$CONFIG" --status-json); [[ $DRY_RUN == false ]] || helper_args+=(--dry-run)
  REPORT_POINT='Developer instructions'; helper_json=$(python3 "$HELPER" "${helper_args[@]}") || die
  helper_status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$helper_json")
  report_point "$helper_status" 'Developer instructions' "$([[ $DRY_RUN == true && $helper_status == changed ]] && printf 'Would remove' || printf '%s' "$([[ $helper_status == changed ]] && printf Removed || printf 'Not present')")"
  report_group 'Agents'
  while IFS= read -r -d '' source; do
    name=$(basename "$source" .toml); target="$CODEX_HOME/agents/$(basename "$source")"
    removal=$(recorded_removal_status "$STATE" "$target")
    case $removal in
      changed) report_point changed "$name" "$([[ $DRY_RUN == true ]] && printf 'Would remove' || printf Removed)" ;;
      preserved) report_point unchanged "$name" 'Preserved local changes' ;;
      absent) report_point unchanged "$name" 'Not installed' ;;
    esac
  done < <(find "$ROOT/agents/native" -maxdepth 1 -type f -name '*.toml' -print0 | sort -z)
  bundle_remove_changed=false bundle_remove_preserved=false
  if [[ -f $STATE ]]; then
    while IFS=$'\t' read -r kind target expected; do
      [[ $target == "$PLUGIN_ROOT/"* ]] || continue
      case $(recorded_removal_status "$STATE" "$target") in
        changed) bundle_remove_changed=true ;;
        preserved) bundle_remove_preserved=true ;;
      esac
    done < "$STATE"
  fi
  remove_recorded_targets "$STATE" "$CODEX_HOME/agents" "$PLUGIN_ROOT"
  if [[ $bundle_remove_changed == true ]]; then
    if [[ $bundle_remove_preserved == true ]]; then
      report_point changed 'Plugin bundle' "$([[ $DRY_RUN == true ]] && printf 'Would remove unchanged files; preserve local changes' || printf 'Removed unchanged files; preserved local changes')"
    else
      report_point changed 'Plugin bundle' "$([[ $DRY_RUN == true ]] && printf 'Would remove unchanged files' || printf 'Removed unchanged files')"
    fi
  elif [[ $bundle_remove_preserved == true ]]; then
    report_point unchanged 'Plugin bundle' 'Preserved local changes'
  else
    report_point unchanged 'Plugin bundle' 'Not installed'
  fi
  if [[ $DRY_RUN == false ]]; then
    rm -f "$STATE"
    find "$PLUGIN_ROOT" -depth -type d -empty -delete 2>/dev/null || true
  fi
  prune_dir "$CODEX_HOME/agents"
  report_group 'Lumen'; report_point unchanged 'Lumen integration' 'Preserved'
  report_result; exit 0
fi

REPORT_POINT='Agent sources'; validate_source_tree "$ROOT/agents/native"
validate_source_tree "$ROOT/skills"
validate_source_tree "$ROOT/plugin"
REPORT_POINT='Target parents'
while IFS= read -r -d '' source; do
  manifest_target_is_safe "$source" "$CODEX_HOME/agents/$(basename "$source")" || die "foreign directory link or directory target protected: $CODEX_HOME/agents/$(basename "$source")"
done < <(find -L "$ROOT/agents/native" -maxdepth 1 -type f -name '*.toml' -print0 | sort -z)
manifest_target_is_safe "$ROOT/plugin/plugin.json" "$PLUGIN_ROOT/.codex-plugin/plugin.json" || die "foreign directory link or directory target protected: $PLUGIN_ROOT/.codex-plugin/plugin.json"
manifest_target_is_safe "$ROOT/plugin/marketplace.json" "$PLUGIN_ROOT/.agents/plugins/marketplace.json" || die "foreign directory link or directory target protected: $PLUGIN_ROOT/.agents/plugins/marketplace.json"
while IFS= read -r -d '' source; do
  relative=${source#"$ROOT/skills/"}
  manifest_target_is_safe "$source" "$PLUGIN_ROOT/skills/$relative" || die "foreign directory link or directory target protected: $PLUGIN_ROOT/skills/$relative"
done < <(filtered_files "$ROOT/skills" | sort -z)
report_group 'Agents'
STATE_TMP=$(mktemp); trap 'rm -f "$STATE_TMP"' EXIT
remove_recorded_target "$STATE" "$LEGACY_PROFILE"
while IFS= read -r -d '' source; do
  name=$(basename "$source" .toml); REPORT_POINT="Agent: $name"
  install_file "$source" "$CODEX_HOME/agents/$(basename "$source")"
  report_point "$INSTALL_RESULT" "$name" "$([[ $DRY_RUN == true && $INSTALL_RESULT == changed ]] && printf 'Would install' || printf '%s' "$([[ $INSTALL_RESULT == changed ]] && printf Installed || printf Current)")"
done < <(find "$ROOT/agents/native" -maxdepth 1 -type f -name '*.toml' -print0 | sort -z)
STALE_CHANGED=false; reconcile_stale_targets "$STATE" "$STATE_TMP" "$CODEX_HOME/agents" "$CODEX_HOME/agents" "$PLUGIN_ROOT"
report_point "$([[ $STALE_CHANGED == true ]] && printf changed || printf unchanged)" 'Stale agent cleanup' "$([[ $STALE_CHANGED == true ]] && printf Reconciled || printf 'Nothing stale')"

report_group 'Plugin bundle'
REPORT_POINT='Plugin bundle'
bundle_changed=false
original_mode=$MODE
MODE=copy
install_file "$ROOT/plugin/plugin.json" "$PLUGIN_ROOT/.codex-plugin/plugin.json"
[[ $INSTALL_RESULT == changed ]] && bundle_changed=true
install_file "$ROOT/plugin/marketplace.json" "$PLUGIN_ROOT/.agents/plugins/marketplace.json"
[[ $INSTALL_RESULT == changed ]] && bundle_changed=true
while IFS= read -r -d '' source; do
  relative=${source#"$ROOT/skills/"}
  MODE=$original_mode
  install_file "$source" "$PLUGIN_ROOT/skills/$relative"
  [[ $INSTALL_RESULT == changed ]] && bundle_changed=true
done < <(filtered_files "$ROOT/skills" | sort -z)
MODE=$original_mode
if [[ -f $STATE ]]; then
  while IFS=$'\t' read -r kind target expected; do
    [[ $kind == link || $kind == copy ]] || continue
    [[ $target == "$PLUGIN_ROOT/"* ]] || continue
    awk -F '\t' -v selected="$target" '$2 == selected { found = 1 } END { exit !found }' "$STATE_TMP" && continue
    remove_recorded_target "$STATE" "$target"
    bundle_changed=true
  done < "$STATE"
fi
report_point "$([[ $bundle_changed == true ]] && printf changed || printf unchanged)" 'Plugin bundle' "$([[ $DRY_RUN == true && $bundle_changed == true ]] && printf 'Would synchronize' || printf '%s' "$([[ $bundle_changed == true ]] && printf Synchronized || printf Current)")"

report_group 'Developer Instructions'
helper_args=(add --config "$CONFIG" --instructions "$INSTRUCTIONS" --status-json); [[ $DRY_RUN == false ]] || helper_args+=(--dry-run)
REPORT_POINT='Developer instructions'; helper_json=$(python3 "$HELPER" "${helper_args[@]}") || die
helper_status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$helper_json")
report_point "$helper_status" 'Developer instructions' "$([[ $DRY_RUN == true && $helper_status == changed ]] && printf 'Would update' || printf '%s' "$([[ $helper_status == changed ]] && printf Updated || printf Current)")"

report_group 'Marketplace / Plugin'
marketplace_current=false
marketplace_registered_at "$PLUGIN_ROOT" && marketplace_current=true
if [[ $marketplace_current == true ]]; then
  report_point unchanged 'Marketplace' 'Already registered'
else
  if [[ $DRY_RUN == false ]]; then
    if plugin_registered; then REPORT_POINT='Plugin'; codex plugin remove basix@basix-local --json >/dev/null 2>&1 || die; fi
    if marketplace_registered; then REPORT_POINT='Marketplace'; codex plugin marketplace remove basix-local --json >/dev/null 2>&1 || die; fi
    REPORT_POINT='Marketplace'; mkdir -p "$CODEX_HOME"; codex plugin marketplace add "$PLUGIN_ROOT" --json >/dev/null || die
  fi
  report_point changed 'Marketplace' "$([[ $DRY_RUN == true ]] && printf 'Would register generated bundle' || printf 'Registered generated bundle')"
fi
if [[ $marketplace_current == true ]] && plugin_registered; then report_point unchanged 'Plugin' 'Already installed'; else
  if [[ $DRY_RUN == false ]]; then REPORT_POINT='Plugin'; codex plugin add basix@basix-local --json >/dev/null || die; fi
  report_point changed 'Plugin' "$([[ $DRY_RUN == true ]] && printf 'Would install' || printf Installed)"
fi
[[ $DRY_RUN == true ]] || mv "$STATE_TMP" "$STATE"

report_group 'Lumen'
if [[ $INSTALL_LUMEN == no ]]; then report_point unchanged 'Lumen integration' 'Skipped';
elif lumen_mcp_installed; then report_point unchanged 'Lumen integration' 'Enabled';
else
  lumen_args=(); [[ $DRY_RUN == false ]] || lumen_args+=(--dry-run); [[ $FORCE == false ]] || lumen_args+=(--force)
  REPORT_POINT='Lumen integration'; "$ROOT/setup/install_ory_lumen.sh" "${lumen_args[@]}" >/dev/null || die
  report_point changed 'Lumen integration' "$([[ $DRY_RUN == true ]] && printf 'Would install' || printf Installed)"
fi
report_result

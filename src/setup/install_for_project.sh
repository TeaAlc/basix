#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/setup/lib/common.sh"
DRY_RUN=false UNINSTALL=false TARGET='' PLAYWRIGHT_CHOICE=''
while (($#)); do case $1 in
  --dry-run) DRY_RUN=true; shift ;;
  --uninstall) UNINSTALL=true; shift ;;
  --playwright) [[ -z $PLAYWRIGHT_CHOICE ]] || die; PLAYWRIGHT_CHOICE=enable; shift ;;
  --no-playwright) [[ -z $PLAYWRIGHT_CHOICE ]] || die; PLAYWRIGHT_CHOICE=disable; shift ;;
  -*) die ;;
  *) [[ -z $TARGET ]] || die; TARGET=$1; shift ;;
esac; done
[[ $UNINSTALL == false || -z $PLAYWRIGHT_CHOICE ]] || die
[[ -n $TARGET ]] || TARGET=.
[[ ! -e $TARGET || -d $TARGET ]] || die
TARGET=$(realpath -m -- "$TARGET"); INSTALL_TARGET_ROOT=$TARGET
CONFIG="$TARGET/.codex/config.toml" STATE="$TARGET/.codex/.basix-install-state" AGENT_DIR="$TARGET/.codex/basix/agents"
HELPER="$ROOT/setup/lib/manage_developer_instructions.py" INSTRUCTIONS="$ROOT/setup/developer_instruction.md"
report_header; report_meta Target "$TARGET"; report_meta 'Dry run' "$DRY_RUN"
REPORT_POINT='Configuration parents'; target_parent_is_safe '' "$CONFIG" || die; target_parent_is_safe '' "$STATE" || die; [[ ! -L $CONFIG && ! -L $STATE ]] || die

playwright_prompt() {
  local response
  if [[ $report_color == true ]]; then
    printf '\033[38;5;208mEnable Playwright sandbox permissions? [y/N]\033[0m ' >&2
  else
    printf 'WARNING: Enable Playwright sandbox permissions? [y/N] ' >&2
  fi
  IFS= read -r response || response=''
  case ${response,,} in y|yes) PLAYWRIGHT_CHOICE=enable ;; *) PLAYWRIGHT_CHOICE=disable ;; esac
  if [[ $PLAYWRIGHT_CHOICE == enable ]]; then
    if [[ $report_color == true ]]; then
      printf '\033[38;5;208mWARNING: Playwright sandbox permissions enabled for this project.\033[0m\n' >&2
    else
      printf 'WARNING: Playwright sandbox permissions enabled for this project.\n' >&2
    fi
  fi
}

if [[ $UNINSTALL == false && -z $PLAYWRIGHT_CHOICE ]]; then
  if [[ -t 0 && -t 1 ]]; then
    playwright_prompt
  else
    printf 'error: noninteractive project installation requires exactly one of --playwright or --no-playwright\n' >&2
    exit 1
  fi
fi

playwright_check() {
  local mode=$1 json
  json=$(python3 "$HELPER" playwright-check --config "$CONFIG" --playwright-mode "$mode" --status-json) || die
  python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$json"
}

playwright_apply() {
  local mode=$1 args=(playwright-add --config "$CONFIG" --status-json)
  if [[ $mode == disable ]]; then args=(playwright-remove --config "$CONFIG" --remove-empty-file --status-json); fi
  [[ $DRY_RUN == false ]] || args+=(--dry-run)
  local json status
  json=$(python3 "$HELPER" "${args[@]}") || die
  status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$json")
  report_point "$status" 'Playwright sandbox permissions' "$mode"
  if [[ $status == changed ]]; then
    local warning=''
    if [[ $mode == enable ]]; then
      warning='This permission change applies only to newly started Codex sessions and permits local port binding without port-level restriction.'
    else
      warning='This permission change applies only to newly started Codex sessions; restart Codex to apply the removal.'
    fi
    if [[ $report_color == true ]]; then printf '\033[38;5;208mWARNING: %s\033[0m\n' "$warning" >&2; else printf 'WARNING: %s\n' "$warning" >&2; fi
  fi
}

if [[ $UNINSTALL == true ]]; then
  REPORT_POINT='Agent configuration'; args=(agent-remove --config "$CONFIG" --agents-source "$ROOT/agents/native" --agents-dir "$AGENT_DIR" --remove-empty-file --status-json --dry-run); python3 "$HELPER" "${args[@]}" >/dev/null || die
  REPORT_POINT='Developer Instructions'; args=(remove --config "$CONFIG" --remove-empty-file --status-json --dry-run); python3 "$HELPER" "${args[@]}" >/dev/null || die
  REPORT_POINT='Playwright sandbox permissions'; playwright_check disable >/dev/null
  report_group 'Playwright sandbox permissions'; playwright_apply disable
  report_group 'Agent configuration'; args=(agent-remove --config "$CONFIG" --agents-source "$ROOT/agents/native" --agents-dir "$AGENT_DIR" --remove-empty-file --status-json); [[ $DRY_RUN == false ]] || args+=(--dry-run); json=$(python3 "$HELPER" "${args[@]}") || die; agent_status=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' <<<"$json"); report_point "$([[ $agent_status == changed ]] && printf changed || printf unchanged)" 'Agent configuration' "$agent_status"
  report_group 'Developer Instructions'; args=(remove --config "$CONFIG" --remove-empty-file --status-json); [[ $DRY_RUN == false ]] || args+=(--dry-run); json=$(python3 "$HELPER" "${args[@]}") || die; status=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' <<<"$json"); report_point "$status" 'Developer instructions' "$status"
  REMOVE_CHANGED=false REMOVE_PRESERVED=false
  report_group 'Skills'; while IFS= read -r -d '' source; do skill=$(basename "$source"); target="$TARGET/.agents/skills/$skill"; status=$(directory_removal_status "$STATE" "$target" "$source"); report_point "$([[ $status == changed || $status == partial ]] && printf changed || printf unchanged)" "$skill" "$status"; remove_recorded_directory "$STATE" "$target" "$source"; done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
  report_group 'Agents'; status=$(directory_removal_status "$STATE" "$AGENT_DIR" "$ROOT/agents/native"); report_point "$([[ $status == changed || $status == partial ]] && printf changed || printf unchanged)" 'Private agents' "$status"; [[ $agent_status == preserved ]] || remove_recorded_directory "$STATE" "$AGENT_DIR" "$ROOT/agents/native"
  remove_recorded_targets "$STATE" "$TARGET/.agents/skills" "$TARGET/.codex/basix"
  prune_dir "$TARGET/.agents/skills"; prune_dir "$TARGET/.agents"; prune_dir "$TARGET/.codex/basix"; prune_dir "$TARGET/.codex"
  if [[ $DRY_RUN == false && $agent_status != preserved && $REMOVE_PRESERVED == false ]]; then rm -f -- "$STATE"; fi
  report_result; exit 0
fi

REPORT_POINT='Codex CLI'; command -v codex >/dev/null || die
REPORT_POINT='Playwright sandbox permissions'; playwright_check "$PLAYWRIGHT_CHOICE" >/dev/null
REPORT_POINT='Developer Instructions'; args=(add --config "$CONFIG" --instructions "$INSTRUCTIONS" --status-json --dry-run); python3 "$HELPER" "${args[@]}" >/dev/null || die
validate_source_tree "$ROOT/agents/native"; validate_source_tree "$ROOT/skills"
python3 "$HELPER" agent-check --config "$CONFIG" --agents-source "$ROOT/agents/native" --agents-dir "$AGENT_DIR" --status-json >/dev/null || die
while IFS= read -r -d '' source; do preflight_tree "$source" "$TARGET/.agents/skills/$(basename "$source")"; done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
preflight_tree "$ROOT/agents/native" "$AGENT_DIR"
STATE_TMP=$(mktemp); trap 'rm -f "$STATE_TMP"' EXIT
report_group 'Skills'; while IFS= read -r -d '' source; do skill=$(basename "$source"); install_tree "$source" "$TARGET/.agents/skills/$skill"; report_point "$INSTALL_RESULT" "$skill" "$INSTALL_RESULT"; done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
report_group 'Agents'; prepare_agent_tree_report "$ROOT/agents/native" "$AGENT_DIR"; install_tree "$ROOT/agents/native" "$AGENT_DIR"; report_agent_tree
STALE_CHANGED=false; reconcile_stale_targets "$STATE" "$STATE_TMP" "$TARGET/.agents/skills" "$TARGET/.codex/basix"; report_point "$([[ $STALE_CHANGED == true ]] && printf changed || printf unchanged)" 'Stale cleanup'
report_group 'Developer Instructions'; args=(add --config "$CONFIG" --instructions "$INSTRUCTIONS" --status-json); [[ $DRY_RUN == false ]] || args+=(--dry-run); json=$(python3 "$HELPER" "${args[@]}") || die; status=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' <<<"$json"); report_point "$status" 'Developer instructions' "$status"
report_group 'Playwright sandbox permissions'; REPORT_POINT='Playwright sandbox permissions'; playwright_apply "$PLAYWRIGHT_CHOICE"
report_group 'Agent configuration'; args=(agent-add --config "$CONFIG" --agents-source "$ROOT/agents/native" --agents-dir "$AGENT_DIR" --status-json); [[ $DRY_RUN == false ]] || args+=(--dry-run); json=$(python3 "$HELPER" "${args[@]}") || die; status=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' <<<"$json"); report_point "$status" 'Agent configuration' "$status"
if [[ $DRY_RUN == false ]]; then mkdir -p "$(dirname "$STATE")"; mv "$STATE_TMP" "$STATE"; fi
report_result

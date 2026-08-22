#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/setup/lib/common.sh"
DRY_RUN=false UNINSTALL=false
while (($#)); do case $1 in --dry-run) DRY_RUN=true; shift ;; --uninstall) UNINSTALL=true; shift ;; *) die ;; esac; done
CODEX_HOME=${CODEX_HOME:-${HOME:?}/.codex}; INSTALL_TARGET_ROOT=$CODEX_HOME
CONFIG="$CODEX_HOME/config.toml" STATE="$CODEX_HOME/.basix-install-state" PLUGIN_ROOT="$CODEX_HOME/basix-plugin-root" AGENT_DIR="$CODEX_HOME/basix/agents"
HELPER="$ROOT/setup/lib/manage_developer_instructions.py" INSTRUCTIONS="$ROOT/setup/developer_instruction.md"
report_header; report_meta Target "$CODEX_HOME"; report_meta 'Dry run' "$DRY_RUN"
REPORT_POINT='Configuration parents'; target_parent_is_safe '' "$CONFIG" || die; target_parent_is_safe '' "$STATE" || die; [[ ! -L $CONFIG && ! -L $STATE ]] || die
command -v codex >/dev/null || die

if [[ $UNINSTALL == true ]]; then
  report_group 'Marketplace / Plugin'; owned=false; state_target_is_managed "$STATE" "$PLUGIN_ROOT/.codex-plugin/plugin.json" && state_target_is_managed "$STATE" "$PLUGIN_ROOT/.agents/plugins/marketplace.json" && owned=true
  if [[ $owned == true ]] && plugin_registered; then [[ $DRY_RUN == true ]] || codex plugin remove basix@basix-local --json >/dev/null 2>&1 || die; report_point changed Plugin Removed; else report_point unchanged Plugin 'Not installed'; fi
  if [[ $owned == true ]] && marketplace_registered_at "$PLUGIN_ROOT"; then [[ $DRY_RUN == true ]] || codex plugin marketplace remove basix-local --json >/dev/null 2>&1 || die; report_point changed Marketplace Removed; else report_point unchanged Marketplace 'Not registered'; fi
  report_group 'Agent configuration'; args=(agent-remove --config "$CONFIG" --agents-source "$ROOT/agents/native" --agents-dir "$AGENT_DIR" --remove-empty-file --status-json); [[ $DRY_RUN == false ]] || args+=(--dry-run); json=$(python3 "$HELPER" "${args[@]}") || die; agent_status=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' <<<"$json"); report_point "$([[ $agent_status == changed ]] && printf changed || printf unchanged)" 'Agent configuration' "$agent_status"
  report_group 'Developer Instructions'; args=(remove --config "$CONFIG" --remove-empty-file --status-json); [[ $DRY_RUN == false ]] || args+=(--dry-run); json=$(python3 "$HELPER" "${args[@]}") || die; status=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' <<<"$json"); report_point "$status" 'Developer instructions' "$status"
  REMOVE_CHANGED=false REMOVE_PRESERVED=false
  report_group 'Agents'; status=$(directory_removal_status "$STATE" "$AGENT_DIR" "$ROOT/agents/native"); report_point "$([[ $status == changed || $status == partial ]] && printf changed || printf unchanged)" 'Private agents' "$status"; [[ $agent_status == preserved ]] || remove_recorded_directory "$STATE" "$AGENT_DIR" "$ROOT/agents/native"
  report_group 'Plugin bundle'; while IFS= read -r -d '' source; do target="$PLUGIN_ROOT/skills/$(basename "$source")"; remove_recorded_directory "$STATE" "$target" "$source"; done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z); remove_recorded_targets "$STATE" "$PLUGIN_ROOT" "$CODEX_HOME/basix"; report_point "$([[ $REMOVE_CHANGED == true ]] && printf changed || printf unchanged)" 'Plugin bundle'
  prune_dir "$PLUGIN_ROOT/.codex-plugin"; prune_dir "$PLUGIN_ROOT/.agents/plugins"; prune_dir "$PLUGIN_ROOT/.agents"; prune_dir "$PLUGIN_ROOT/skills"; prune_dir "$PLUGIN_ROOT"; prune_dir "$CODEX_HOME/basix"
  if [[ $DRY_RUN == false && $agent_status != preserved && $REMOVE_PRESERVED == false ]]; then rm -f -- "$STATE"; fi
  report_result; exit 0
fi

validate_source_tree "$ROOT/agents/native"; validate_source_tree "$ROOT/skills"; validate_source_tree "$ROOT/plugin"
python3 "$HELPER" agent-check --config "$CONFIG" --agents-source "$ROOT/agents/native" --agents-dir "$AGENT_DIR" --status-json >/dev/null || die
preflight_file "$ROOT/plugin/plugin.json" "$PLUGIN_ROOT/.codex-plugin/plugin.json"; preflight_file "$ROOT/plugin/marketplace.json" "$PLUGIN_ROOT/.agents/plugins/marketplace.json"
preflight_tree "$ROOT/agents/native" "$AGENT_DIR"; while IFS= read -r -d '' source; do preflight_tree "$source" "$PLUGIN_ROOT/skills/$(basename "$source")"; done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
STATE_TMP=$(mktemp); trap 'rm -f "$STATE_TMP"' EXIT
report_group 'Agents'; prepare_agent_tree_report "$ROOT/agents/native" "$AGENT_DIR"; install_tree "$ROOT/agents/native" "$AGENT_DIR"; report_agent_tree
report_group 'Plugin bundle'; bundle_changed=false; install_file "$ROOT/plugin/plugin.json" "$PLUGIN_ROOT/.codex-plugin/plugin.json"; [[ $INSTALL_RESULT == changed ]] && bundle_changed=true; install_file "$ROOT/plugin/marketplace.json" "$PLUGIN_ROOT/.agents/plugins/marketplace.json"; [[ $INSTALL_RESULT == changed ]] && bundle_changed=true
while IFS= read -r -d '' source; do install_tree "$source" "$PLUGIN_ROOT/skills/$(basename "$source")"; [[ $INSTALL_RESULT == changed ]] && bundle_changed=true; done < <(find "$ROOT/skills" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
STALE_CHANGED=false; reconcile_stale_targets "$STATE" "$STATE_TMP" "$PLUGIN_ROOT" "$CODEX_HOME/basix"; [[ $STALE_CHANGED == true ]] && bundle_changed=true; report_point "$([[ $bundle_changed == true ]] && printf changed || printf unchanged)" 'Plugin bundle'
report_group 'Marketplace / Plugin'; if marketplace_registered_at "$PLUGIN_ROOT"; then report_point unchanged Marketplace 'Already registered'; else [[ $DRY_RUN == true ]] || { plugin_registered && codex plugin remove basix@basix-local --json >/dev/null 2>&1 || true; marketplace_registered && codex plugin marketplace remove basix-local --json >/dev/null 2>&1 || true; mkdir -p "$CODEX_HOME"; codex plugin marketplace add "$PLUGIN_ROOT" --json >/dev/null || die; }; report_point changed Marketplace Registered; fi
if plugin_registered; then report_point unchanged Plugin 'Already installed'; else [[ $DRY_RUN == true ]] || codex plugin add basix@basix-local --json >/dev/null || die; report_point changed Plugin Installed; fi
report_group 'Developer Instructions'; args=(add --config "$CONFIG" --instructions "$INSTRUCTIONS" --status-json); [[ $DRY_RUN == false ]] || args+=(--dry-run); json=$(python3 "$HELPER" "${args[@]}") || die; status=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' <<<"$json"); report_point "$status" 'Developer instructions' "$status"
report_group 'Agent configuration'; args=(agent-add --config "$CONFIG" --agents-source "$ROOT/agents/native" --agents-dir "$AGENT_DIR" --status-json); [[ $DRY_RUN == false ]] || args+=(--dry-run); json=$(python3 "$HELPER" "${args[@]}") || die; status=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["status"])' <<<"$json"); report_point "$status" 'Agent configuration' "$status"
[[ $DRY_RUN == true ]] || mv "$STATE_TMP" "$STATE"; report_result

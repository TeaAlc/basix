#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Resolved from this bundle's absolute runtime root.
# shellcheck disable=SC1091
source "$ROOT/setup/lib/common.sh"
MODE=link DRY_RUN=false FORCE=false UNINSTALL=false INSTALL_LUMEN=yes
while (($#)); do
  case $1 in
    --mode) (($# >= 2)) || die '--mode requires a value'; MODE=$2; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    --install-lumen) (($# >= 2)) || die '--install-lumen requires yes or no'; INSTALL_LUMEN=$2; shift 2 ;;
    --uninstall) UNINSTALL=true; shift ;;
    *) die "unknown option: $1" ;;
  esac
done
require_mode "$MODE"
require_yes_no --install-lumen "$INSTALL_LUMEN"
CODEX_HOME=${CODEX_HOME:-${HOME:?}/.codex}
CONFIG="$CODEX_HOME/config.toml"
STATE="$CODEX_HOME/.basix-install-state"
HELPER="$ROOT/setup/lib/manage_developer_instructions.py"
INSTRUCTIONS="$ROOT/setup/developer_instruction.md"
LEGACY_PROFILE="$CODEX_HOME/basix-luna-researcher.config.toml"

if [[ $UNINSTALL == true ]]; then
  command -v codex >/dev/null || die 'Codex CLI not found'
  note 'Removing Basix plugin integration'
  if [[ $DRY_RUN == false ]]; then
    codex plugin remove basix@basix-local --json >/dev/null 2>&1 || true
    codex plugin marketplace remove basix-local --json >/dev/null 2>&1 || true
  fi
  helper_args=(remove --config "$CONFIG")
  [[ $DRY_RUN == false ]] || helper_args+=(--dry-run)
  python3 "$HELPER" "${helper_args[@]}"
  remove_recorded_targets "$STATE"
  [[ $DRY_RUN == true ]] || rm -f "$STATE"
  prune_dir "$CODEX_HOME/agents"
  exit 0
fi

command -v codex >/dev/null || die 'Codex CLI not found'
if [[ $INSTALL_LUMEN == yes ]] && ! lumen_mcp_installed; then
  lumen_args=()
  [[ $DRY_RUN == false ]] || lumen_args+=(--dry-run)
  [[ $FORCE == false ]] || lumen_args+=(--force)
  "$ROOT/setup/install_ory_lumen.sh" "${lumen_args[@]}"
fi
STATE_TMP=$(mktemp)
trap 'rm -f "$STATE_TMP"' EXIT
# Upgrade cleanup is state-gated: only a previously managed, unchanged legacy
# profile is removed. Foreign or locally modified files are preserved.
remove_recorded_target "$STATE" "$LEGACY_PROFILE"
while IFS= read -r -d '' source; do
  install_file "$source" "$CODEX_HOME/agents/$(basename "$source")"
done < <(find "$ROOT/agents/native" -maxdepth 1 -type f -name '*.toml' -print0 | sort -z)
helper_args=(add --config "$CONFIG" --instructions "$INSTRUCTIONS")
[[ $DRY_RUN == false ]] || helper_args+=(--dry-run)
python3 "$HELPER" "${helper_args[@]}"
if [[ $DRY_RUN == true ]]; then
  note "Would register marketplace $ROOT"
  note 'Would install basix@basix-local'
else
  mkdir -p "$CODEX_HOME"
  codex plugin marketplace add "$ROOT" --json >/dev/null
  codex plugin add basix@basix-local --json >/dev/null
  mv "$STATE_TMP" "$STATE"
fi
note 'Basix global installation complete.'

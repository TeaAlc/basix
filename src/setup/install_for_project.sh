#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Resolved from this bundle's absolute runtime root.
# shellcheck disable=SC1091
source "$ROOT/setup/lib/common.sh"
MODE=link DRY_RUN=false FORCE=false UNINSTALL=false TARGET='' INSTALL_LUMEN=yes LUMEN_INDEX=ask
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
[[ -n $TARGET ]] || die 'TARGET is required'
require_mode "$MODE"
require_yes_no --install-lumen "$INSTALL_LUMEN"
[[ $LUMEN_INDEX == ask || $LUMEN_INDEX == yes || $LUMEN_INDEX == no ]] || die "invalid --lumen-index value: $LUMEN_INDEX (expected ask, yes, or no)"
if [[ -e $TARGET && ! -d $TARGET ]]; then die "TARGET is not a directory: $TARGET"; fi
TARGET=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TARGET")
BUNDLE="$TARGET/.basix"
CONFIG="$TARGET/.codex/config.toml"
STATE="$TARGET/.codex/.basix-install-state"
HELPER="$ROOT/setup/lib/manage_developer_instructions.py"
INSTRUCTIONS="$ROOT/setup/developer_instruction.md"
SKILL="$TARGET/.agents/skills/basix"
AUTHORING_SKILL="$TARGET/.agents/skills/basix-agent-authoring"
AUTHORING_SKILL_SOURCE="$ROOT/skills/basix-agent-authoring"

if [[ $UNINSTALL == true ]]; then
  helper_args=(remove --config "$CONFIG" --remove-empty-file)
  [[ $DRY_RUN == false ]] || helper_args+=(--dry-run)
  python3 "$HELPER" "${helper_args[@]}"
  remove_recorded_targets "$STATE"
  [[ $DRY_RUN == true ]] || rm -f "$STATE"
  if [[ -d $AUTHORING_SKILL_SOURCE ]]; then
    while IFS= read -r -d '' source_dir; do
      relative_dir=${source_dir#"$AUTHORING_SKILL_SOURCE"}
      prune_dir "$AUTHORING_SKILL$relative_dir"
    done < <(find "$AUTHORING_SKILL_SOURCE" -depth -type d -print0 | sort -zr)
  fi
  prune_dir "$SKILL/agents"; prune_dir "$SKILL"
  prune_dir "$TARGET/.agents/skills"; prune_dir "$TARGET/.agents"
  prune_dir "$TARGET/.codex/agents"; prune_dir "$TARGET/.codex"
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
if [[ -e $BUNDLE || -L $BUNDLE ]]; then
  valid=false
  [[ $MODE == link && -L $BUNDLE && $(readlink "$BUNDLE") == "$ROOT" ]] && valid=true
  [[ $MODE == copy && -d $BUNDLE && ! -L $BUNDLE ]] && valid=true
  [[ $valid == true || $FORCE == true ]] || die "target conflict: $BUNDLE (use --force)"
  if [[ $valid == false && $DRY_RUN == false ]]; then
    if [[ -d $BUNDLE && ! -L $BUNDLE ]]; then rm -rf "$BUNDLE"; else rm -f "$BUNDLE"; fi
  fi
fi
if [[ ! -e $BUNDLE && ! -L $BUNDLE ]]; then
  note "Installing bundle $BUNDLE ($MODE)"
  if [[ $DRY_RUN == false ]]; then
    mkdir -p "$TARGET"
    if [[ $MODE == link ]]; then ln -s "$ROOT" "$BUNDLE"; else cp -R "$ROOT" "$BUNDLE"; fi
  fi
fi
if [[ $DRY_RUN == true ]]; then BUNDLE_SOURCE=$ROOT; else BUNDLE_SOURCE=$BUNDLE; fi
install_file "$BUNDLE_SOURCE/skills/basix"/SKILL.md "$SKILL/SKILL.md"
install_file "$BUNDLE_SOURCE/skills/basix/agents/openai.yaml" "$SKILL/agents/openai.yaml"
while IFS= read -r -d '' source; do
  relative=${source#"$BUNDLE_SOURCE/skills/basix-agent-authoring/"}
  install_file "$source" "$AUTHORING_SKILL/$relative"
done < <(find "$BUNDLE_SOURCE/skills/basix-agent-authoring" -type f -print0 | sort -z)
while IFS= read -r -d '' source; do
  install_file "$source" "$TARGET/.codex/agents/$(basename "$source")"
done < <(find "$BUNDLE_SOURCE/agents/native" -maxdepth 1 -type f -name '*.toml' -print0 | sort -z)
if [[ $MODE == link ]]; then
  record_target bundle-link "$BUNDLE" "$ROOT"
else
  if [[ $DRY_RUN == true ]]; then record_target bundle-copy "$BUNDLE" "$(sha256_tree "$ROOT")"; else record_target bundle-copy "$BUNDLE" "$(sha256_tree "$BUNDLE")"; fi
fi
helper_args=(add --config "$CONFIG" --instructions "$INSTRUCTIONS")
[[ $DRY_RUN == false ]] || helper_args+=(--dry-run)
python3 "$HELPER" "${helper_args[@]}"
if [[ $DRY_RUN == false ]]; then mkdir -p "$(dirname "$STATE")"; mv "$STATE_TMP" "$STATE"; fi

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
      note "Would run lumen index . in $TARGET"
    elif launcher=$(lumen_launcher); then
      note "Running lumen index . in $TARGET"
      (cd "$TARGET" && "$launcher" index .)
    else
      orange_warning 'Lumen MCP is registered, but its canonical Ory launcher could not be verified; skipping lumen index .'
    fi
  fi
else
  orange_warning 'Lumen is not installed as an enabled Codex MCP server; lumen index . is unavailable.'
fi
note 'Basix project installation complete.'

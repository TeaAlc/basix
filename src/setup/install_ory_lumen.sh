#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Resolved from this bundle's absolute runtime root.
# shellcheck disable=SC1091
source "$ROOT/setup/lib/common.sh"
DRY_RUN=false FORCE=false
while (($#)); do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

CODEX_HOME=${CODEX_HOME:-${HOME:?}/.codex}
LUMEN_HOME="$CODEX_HOME/lumen"
SKILL_LINK="${HOME:?}/.agents/skills/lumen"
REPOSITORY=https://github.com/ory/lumen.git

command -v codex >/dev/null || die 'Codex CLI not found'
registration_status=$(lumen_mcp_registration_status "$LUMEN_HOME/scripts/run") || die 'Codex CLI not found'
[[ $registration_status != conflict ]] || die 'conflicting Lumen MCP registration'
if [[ $registration_status == matching && -d $LUMEN_HOME && -x $LUMEN_HOME/scripts/run && -d $LUMEN_HOME/skills && -L $SKILL_LINK && $(readlink "$SKILL_LINK") == "$LUMEN_HOME/skills" ]]; then
  note 'Ory Lumen is already registered as a Codex MCP server.'
  exit 0
fi

if [[ -e $LUMEN_HOME || -L $LUMEN_HOME ]]; then
  [[ -d $LUMEN_HOME && -x $LUMEN_HOME/scripts/run && -d $LUMEN_HOME/skills ]] || die "target conflict: $LUMEN_HOME"
else
  command -v git >/dev/null || die 'Git not found'
  note "Installing Ory Lumen in $LUMEN_HOME"
  if [[ $DRY_RUN == false ]]; then
    mkdir -p "$CODEX_HOME"
    git clone "$REPOSITORY" "$LUMEN_HOME"
  fi
fi

if [[ -e $SKILL_LINK || -L $SKILL_LINK ]]; then
  if [[ -L $SKILL_LINK && $(readlink "$SKILL_LINK") == "$LUMEN_HOME/skills" ]]; then
    :
  elif [[ $FORCE == true && ! -d $SKILL_LINK ]]; then
    note "Replacing conflicting Lumen skill link: $SKILL_LINK"
    [[ $DRY_RUN == true ]] || rm -f "$SKILL_LINK"
  else
    die "target conflict: $SKILL_LINK (use --force for a file or link)"
  fi
fi
if [[ ! -e $SKILL_LINK && ! -L $SKILL_LINK ]]; then
  note "Installing Lumen skills at $SKILL_LINK"
  if [[ $DRY_RUN == false ]]; then
    mkdir -p "$(dirname "$SKILL_LINK")"
    ln -s "$LUMEN_HOME/skills" "$SKILL_LINK"
  fi
fi

if [[ $registration_status == matching ]]; then
  note 'Ory Lumen is already registered as a Codex MCP server.'
elif [[ $DRY_RUN == true ]]; then
  note "Would register Lumen MCP with $LUMEN_HOME/scripts/run"
else
  codex mcp add lumen -- "$LUMEN_HOME/scripts/run" stdio >/dev/null
  lumen_mcp_installed "$LUMEN_HOME/scripts/run" || die 'Lumen MCP registration could not be verified'
fi
note 'Ory Lumen installation complete.'

#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AGENT="$ROOT/agents/native/basix-pager.toml"
PROFILE='' PROMPT='' WORKDIR=$PWD OUTPUT='' TRACE=''

usage() {
  printf 'Usage: %s --profile PROFILE [--prompt TEXT] [--workdir DIR] [--output FILE] [--trace FILE]\n' "$0"
  printf 'Profiles: ui_ux, frontend, backend_web, fullstack, integration\n'
}

while (($#)); do
  case $1 in
    --profile) (($# >= 2)) || { usage >&2; exit 2; }; PROFILE=$2; shift 2 ;;
    --prompt) (($# >= 2)) || { usage >&2; exit 2; }; PROMPT=$2; shift 2 ;;
    --workdir) (($# >= 2)) || { usage >&2; exit 2; }; WORKDIR=$2; shift 2 ;;
    --output) (($# >= 2)) || { usage >&2; exit 2; }; OUTPUT=$2; shift 2 ;;
    --trace) (($# >= 2)) || { usage >&2; exit 2; }; TRACE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case $PROFILE in
  ui_ux) [[ -n $PROMPT ]] || PROMPT='Implement and verify a responsive, accessible interface within the assigned scope.' ;;
  frontend) [[ -n $PROMPT ]] || PROMPT='Implement and verify a browser-side feature with loading, error, and interaction states.' ;;
  backend_web) [[ -n $PROMPT ]] || PROMPT='Implement and verify a validated web endpoint with authorization and contract tests.' ;;
  fullstack) [[ -n $PROMPT ]] || PROMPT='Implement and verify one cohesive client/server feature with complete data flow.' ;;
  integration) [[ -n $PROMPT ]] || PROMPT='Verify compatible frontend and backend implementations against the assigned interface contract.' ;;
  *) printf 'A valid --profile is required.\n' >&2; usage >&2; exit 2 ;;
esac
[[ -d $WORKDIR ]] || { printf 'Working directory does not exist: %s\n' "$WORKDIR" >&2; exit 2; }
command -v codex >/dev/null || { printf 'Codex CLI not found.\n' >&2; exit 3; }

readarray -d '' config < <(python3 - "$AGENT" "$PROFILE" <<'PY'
import json
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    agent = tomllib.load(handle)
profile = sys.argv[2]
instructions = agent["developer_instructions"]
required = ["ui_ux", "frontend", "backend_web", "fullstack", "integration"]
if agent["name"] != "basix_pager" or agent["model"] != "gpt-5.6-luna" or agent["model_reasoning_effort"] != "max":
    raise SystemExit("invalid pager model configuration")
if agent["sandbox_mode"] != "workspace-write":
    raise SystemExit("invalid pager sandbox configuration")
if profile not in required or f"`{profile}`" not in instructions:
    raise SystemExit("profile is not supported by the canonical pager")
for value in (agent["model"], agent["model_reasoning_effort"], agent["sandbox_mode"], instructions):
    sys.stdout.write(json.dumps(value) + "\0")
PY
)
(( ${#config[@]} == 4 )) || { printf 'Could not extract pager configuration.\n' >&2; exit 4; }

task_prompt="task_profile=${PROFILE}\n\n${PROMPT}"
args=(exec --ephemeral --ignore-user-config --ignore-rules
  --skip-git-repo-check --sandbox "${config[2]//\"/}" --model "${config[0]//\"/}"
  -c "model_reasoning_effort=${config[1]}" -c "developer_instructions=${config[3]}"
  --cd "$WORKDIR" --json)
[[ -z $OUTPUT ]] || args+=(--output-last-message "$OUTPUT")
if [[ -n $TRACE ]]; then
  codex "${args[@]}" "$task_prompt" >"$TRACE"
else
  exec codex "${args[@]}" "$task_prompt"
fi

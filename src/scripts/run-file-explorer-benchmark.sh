#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AGENT="$ROOT/agents/native/basix-file-explorer.toml"
PROMPT='' WORKDIR=$PWD OUTPUT='' TRACE=''
usage() {
  printf 'Usage: %s --prompt TEXT [--workdir DIR] [--output FILE] [--trace FILE]\n' "$0"
}
while (($#)); do
  case $1 in
    --prompt) (($# >= 2)) || { usage >&2; exit 2; }; PROMPT=$2; shift 2 ;;
    --workdir) (($# >= 2)) || { usage >&2; exit 2; }; WORKDIR=$2; shift 2 ;;
    --output) (($# >= 2)) || { usage >&2; exit 2; }; OUTPUT=$2; shift 2 ;;
    --trace) (($# >= 2)) || { usage >&2; exit 2; }; TRACE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n $PROMPT ]] || { printf 'A prompt is required.\n' >&2; exit 2; }
[[ -d $WORKDIR ]] || { printf 'Working directory does not exist: %s\n' "$WORKDIR" >&2; exit 2; }
command -v codex >/dev/null || { printf 'Codex CLI not found.\n' >&2; exit 3; }

readarray -d '' config < <(python3 - "$AGENT" <<'PY'
import json
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    agent = tomllib.load(handle)
instructions = agent["developer_instructions"]
start = "<!-- basix-file-explorer:search:start -->"
end = "<!-- basix-file-explorer:search:end -->"
if instructions.count(start) != 1 or instructions.count(end) != 1:
    raise SystemExit("invalid explorer search markers")
search = instructions.split(start, 1)[1].split(end, 1)[0].strip()
for value in (agent["model"], agent["model_reasoning_effort"], agent["sandbox_mode"], search):
    sys.stdout.write(json.dumps(value) + "\0")
PY
)
(( ${#config[@]} == 4 )) || { printf 'Could not extract explorer configuration.\n' >&2; exit 4; }

args=(exec --ephemeral --ignore-user-config --ignore-rules
  --skip-git-repo-check
  --sandbox "${config[2]//\"/}" --model "${config[0]//\"/}"
  -c "model_reasoning_effort=${config[1]}" -c 'web_search="disabled"'
  -c "developer_instructions=${config[3]}" --cd "$WORKDIR" --json)
[[ -z $OUTPUT ]] || args+=(--output-last-message "$OUTPUT")
if [[ -n $TRACE ]]; then
  codex "${args[@]}" "$PROMPT" >"$TRACE"
else
  exec codex "${args[@]}" "$PROMPT"
fi

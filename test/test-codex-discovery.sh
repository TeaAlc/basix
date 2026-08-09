#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v codex >/dev/null || {
  printf 'error: codex CLI is required for the live discovery test\n' >&2
  exit 1
}

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
project="$case_dir/project"
schema="$case_dir/schema.json"
events="$case_dir/events.jsonl"
last="$case_dir/last.json"
mkdir -p "$project"
git -C "$project" init -q

"$ROOT/src/setup/install_for_project.sh" "$project" >/dev/null

cat >"$schema" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "additionalProperties": false,
  "required": ["skills", "subagents", "basix_instructions"],
  "properties": {
    "skills": {"type": "array", "items": {"type": "string"}},
    "subagents": {"type": "array", "items": {"type": "string"}},
    "basix_instructions": {"type": "boolean"}
  }
}
JSON

prompt='I explicitly request sub-agent delegation for a later task. Do not call any tools in this turn. Using exclusively your initial context, return the names of all visible skills and every available basix_ prefixed subagent role, plus whether Basix developer instructions are present. Put those role identifiers in subagents. Return only JSON matching the supplied schema.'
if ! codex exec --ephemeral --sandbox read-only --ignore-user-config --enable multi_agent \
  -c "projects={ \"$project\" = { trust_level = \"trusted\" } }" \
  -c agents.max_threads=4 \
  -C "$project" --output-schema "$schema" --json \
  --output-last-message "$last" "$prompt" >"$events"; then
  printf '%s\n' 'error: codex exec discovery turn failed; verify authentication, network access, and usage limits' >&2
  if [[ -s $events ]]; then
    printf '%s\n' 'Codex JSONL diagnostics:' >&2
    tail -n 20 "$events" >&2
  fi
  exit 1
fi

python3 - "$events" "$last" <<'PY'
import json
import sys
from pathlib import Path

events_path, last_path = map(Path, sys.argv[1:])
for number, line in enumerate(events_path.read_text(encoding='utf-8').splitlines(), 1):
    event = json.loads(line)
    serialized = json.dumps(event, sort_keys=True).lower()
    forbidden = ('tool_call', 'command_execution', 'mcp_tool', 'web_search')
    assert not any(value in serialized for value in forbidden), (
        f'unexpected tool event on JSONL line {number}: {event}'
    )

result = json.loads(last_path.read_text(encoding='utf-8'))
print('Codex discovery response: ' + json.dumps(result, sort_keys=True))
required_skills = {'basix', 'basix-agent-authoring'}
required_agents = {
    'basix_file_explorer',
    'basix_pager',
    'basix_researcher',
    'basix_verifier',
}
skills = set(result['skills'])
agents = set(result['subagents'])
assert required_skills <= skills, f'missing skills: {sorted(required_skills - skills)}'
assert required_agents <= agents, f'missing subagents: {sorted(required_agents - agents)}'
assert result['basix_instructions'] is True, 'Basix developer instructions were not discovered'
print('ok - live Codex discovery found Basix skills, subagents, and instructions without tools')
PY

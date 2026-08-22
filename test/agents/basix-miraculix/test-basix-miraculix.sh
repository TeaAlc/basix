#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/src/agents/native/basix-miraculix.toml" <<'PY'
import sys
import tomllib
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
agent = tomllib.loads(text)
assert agent["name"] == "basix_miraculix"
assert agent["model"] == "gpt-5.6-sol"
assert agent["model_reasoning_effort"] == "low"
assert agent["sandbox_mode"] == "read-only"
model_index = text.splitlines().index('model = "gpt-5.6-sol"')
assert text.splitlines()[model_index - 1] == "# basix-agent-authoring: explicit-model-override"
instructions = agent["developer_instructions"]
for phrase in (
    "combined length of only the", "question values", "1024 Unicode characters",
    "inherit no parent state",
    "use no domain tools, files, web access, or subagents",
    "`final_result` whose `data.answer`", "complete answer",
    "exactly `Das weiß ich nicht`", "Multiple questions may therefore mix safe",
    "time-sensitive answers",
    "very strongly supported", "code is `invalid_request`",
):
    assert phrase in instructions, phrase
print("ok - basix_miraculix definition")
PY

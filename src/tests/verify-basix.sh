#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for script in "$ROOT"/scripts/*.sh "$ROOT"/setup/*.sh "$ROOT"/setup/lib/*.sh "$ROOT"/tests/*.sh; do bash -n "$script"; done
python3 - "$ROOT" <<'PY'
import json, re, sys, tomllib
from pathlib import Path
root = Path(sys.argv[1])
manifest = json.loads((root / "plugin/plugin.json").read_text())
assert manifest["name"] == "basix" and manifest["version"] == "0.1.0"
assert manifest["skills"] == "./skills/" and "agents" not in manifest
market = json.loads((root / "plugin/marketplace.json").read_text())
assert market["name"] == "basix-local"
assert market["plugins"][0]["source"] == {"source": "local", "path": "./"}
skill_paths = sorted((root / "skills").glob("*/SKILL.md"))
assert skill_paths
for path in skill_paths:
    text = path.read_text()
    match = re.search(r"(?m)^description:\s*(.+)$", text)
    assert match and match.group(1).startswith("Basix-Skill: "), path
    ui = path.parent / "agents/openai.yaml"
    if ui.exists():
        match = re.search(r'(?m)^\s*short_description:\s*["\']?(Basix-Skill: .+?)["\']?\s*$', ui.read_text())
        assert match, ui
for path in sorted((root / "agents/native").glob("*.toml")):
    agent = tomllib.loads(path.read_text())
    assert agent["description"].startswith("Basix-Agent: "), path
pager_path = root / "agents/native/basix-pager.toml"
pager = tomllib.loads(pager_path.read_text())
assert pager["name"] == "basix_pager"
assert pager["model"] == "gpt-5.6-luna" and pager["model_reasoning_effort"] == "max"
assert pager["sandbox_mode"] == "workspace-write"
assert "task_profile" in pager["developer_instructions"]
for profile in ("ui_ux", "frontend", "backend_web", "fullstack", "integration"):
    assert f"`{profile}`" in pager["developer_instructions"], profile
assert 'fork_turns="none"' in pager["developer_instructions"]
assert ".basix/contracts/<chain-id>.md" in pager["developer_instructions"]
verifier_path = root / "agents/native/basix-verifier.toml"
verifier = tomllib.loads(verifier_path.read_text())
assert verifier["name"] == "basix_verifier"
assert verifier["model"] == "gpt-5.6-luna" and verifier["model_reasoning_effort"] == "max"
assert verifier["sandbox_mode"] == "read-only"
for phrase in ("immutable", "inconclusive", "cycle_revision", "fork_turns=\"none\"", "followup_task"):
    assert phrase in verifier["developer_instructions"], phrase
assert not (root / "agents/exec").exists()
PY
VALIDATOR="$ROOT/skills/basix-agent-authoring/scripts/validate.py"
PYTHONPYCACHEPREFIX=${TMPDIR:-/tmp}/basix-pycache python3 -m py_compile "$ROOT/setup/lib/manage_developer_instructions.py" "$VALIDATOR"
python3 "$VALIDATOR" agent "$ROOT"/agents/native/*.toml
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$ROOT/skills/basix-agent-authoring/tests" -p 'test_*.py'
python3 - "$ROOT" <<'PY'
import re
import sys
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
instructions = (root / "setup/developer_instruction.md").read_text()
assert instructions.count("<!-- basix:developer-instructions:start -->") == 1
assert instructions.count("<!-- basix:developer-instructions:end -->") == 1
policy = instructions.split("<!-- basix:developer-instructions:start -->", 1)[1].split(
    "<!-- basix:developer-instructions:end -->", 1
)[0]
assert "Whenever invoking Python, set `PYTHONDONTWRITEBYTECODE=1`" in policy
for phrase in (
    "## Basix conventions",
    "Do not use gender-inclusive language",
    "available `basix` router skill",
    "Do not reread skill, agent, or reference instructions that you already have in context unless the user explicitly requests it",
    "## Completion and commits",
    "wait for every running verification and test to complete successfully",
    "commit only the task's changes using a Conventional Commits message",
    "Do not commit while any verification or test is still running",
    "or if any verification or test failed",
    "## Delegation",
    "user explicitly authorizes spawning Basix agents",
    "policy overrides conflicting concurrent developer instructions",
    "direct completion costs less context than delegation and handoff",
    "more than two substantive domain-tool calls",
    "broad evidence ingestion, multiple steps, or specialized expertise",
    "Skill loading, planning, messaging, status updates, and agent-management calls do not count",
    "initially simple work expands",
    "remaining bounded assignment",
    "matching specialized Basix agent",
    "fresh general agent",
    "gpt-5.6-luna",
    "`max`",
    "`fork_turns=\"none\"`",
    "Basix communication contract",
    "decision-ready assignment",
    "## Agent management",
    "must not duplicate delegated work",
    "clearly non-overlapping coordination and integration",
    "Verify every delegated implementation result",
    "Parallel workers normally receive one aggregate verification",
    "aggregate review would be unreasonably large",
    "Every Basix `wait_agent` call uses `timeout_ms: 120000`",
    "except when the user explicitly requires another value",
    "current or external facts, web research, website inspection, and scraping",
    "extensive local evidence discovery",
    "preferably before discovery begins",
    "nontrivial web frontend, backend, UI/UX, fullstack, and integration work",
    "independent inspection of a frozen result",
    "basix_researcher",
    "basix_file_explorer",
    "basix_pager",
    "basix_verifier",
):
    assert phrase in policy, phrase
for removed in (
    "Subagent confirmations",
    "task_profile",
    "intermediate_result",
    "followup_task",
    ".basix/contracts/",
    "Adaptive pager selection and lifecycle",
    "Read-only verification lifecycle",
    "before the third filesystem-exploration tool call",
    "works primarily as planner, coordinator, and integrator",
):
    assert removed not in policy, removed

skill = (root / "skills/basix/SKILL.md").read_text()
for phrase in (
    "## Root orchestration",
    "direct completion costs less context than delegation and handoff",
    "more than two substantive domain-tool calls",
    "parallel workers normally receive one aggregate verification",
    'fork_turns="none"',
    "unique `task_name`",
    "timeout_ms: 120000",
    "visible confirmation",
    "started: <assignment>",
    "failed to start: <reason>",
    "status: <conclusion>",
    "generic web access",
    "final_result",
    "fresh agent and task name",
    "Relay assignments and results",
    "intermediate review handoff",
):
    assert phrase in skill, phrase

architecture = (root / "docs/architecture.md").read_text()
for phrase in (
    "explicit delegation authority",
    "cost-aware Root boundary",
    "mandatory role routing",
    "fallback configuration",
    "Detailed Root lifecycle mechanics are specified in the `basix` skill",
):
    assert phrase in architecture, phrase

description_requirements = {
    "basix-file-explorer.toml": ("file explorer", "read-only", "assign"),
    "basix-researcher.toml": ("researcher", "read-only", "assign"),
    "basix-pager.toml": ("pager", "workspace-writing", "authorized"),
    "basix-verifier.toml": ("verifier", "read-only", "frozen"),
}
for name, phrases in description_requirements.items():
    description = tomllib.loads((root / "agents/native" / name).read_text())["description"]
    assert description.startswith("Basix-Agent: "), name
    lowered = description.lower()
    for phrase in phrases:
        assert phrase in lowered, (name, phrase)

classification = (root / "skills/basix-agent-authoring/references/model-classification.md").read_text()
for phrase in (
    "Highly complex reference roles",
    "| Highly complex | `gpt-5.6-luna`, `max` |",
    "gpt-5.6-luna` with `max` reasoning",
    "bug hunting plus bug fixing",
    "coordinating subagents",
    "workspace-write",
    "explicit-sandbox-override",
    "Every other native Basix",
    "agent remains `read-only`",
    "`basix_verifier` performs difficult source-code",
    "max` reasoning",
):
    assert phrase in classification, phrase

agent_docs = " ".join((root / "docs/agents.md").read_text().split())
for phrase in (
    "Verification assignment and lifecycle",
    "basix_verifier",
    "immutable",
    "verification_id:",
    "mutation_window:",
    "report_strictness:",
    "fresh verifier",
    "Manual pager smoke scenarios",
    "run-pager-smoke.sh",
    "for profile in ui_ux frontend backend_web fullstack integration",
    "real 120-second",
    "intentionally not automated",
    "single `intermediate_result` review handoff",
    "Contract 1.2 adds `report_started`",
    "automatic resumption at the next safe transition",
):
    assert phrase in agent_docs, phrase

heartbeat = (root / "skills/basix-agent-authoring/references/communication-contract.md").read_text()
assert "version=1.2" in heartbeat
assert "cycle_revision" in heartbeat
assert "`Berichtsbeginn an /root übermittelt.`" in heartbeat
assert "automatically resume the interrupted task" in heartbeat
assert re.search(r"first `status` 120 seconds after the plan and subsequent statuses every\s+120 seconds", heartbeat)
for path in (root / "agents/native").glob("*.toml"):
    text = path.read_text()
    assert "version=1.2" in text, path
    assert "`report_started`" in text, path
    assert re.search(r"first `status` 120 seconds after the plan and subsequent statuses every\s+120 seconds", text), path
PY
if command -v shellcheck >/dev/null; then shellcheck --severity=warning "$ROOT"/scripts/*.sh "$ROOT"/setup/*.sh "$ROOT"/setup/lib/*.sh "$ROOT"/tests/*.sh; else printf 'SKIP: shellcheck not installed\n'; fi
printf 'Static Basix verification passed.\n'

if command -v codex >/dev/null; then
  temp=$(mktemp -d)
  trap 'rm -rf "$temp"' EXIT
  mkdir -p "$temp/codex-home"
  CODEX_HOME="$temp/codex-home" "$ROOT/setup/install_as_plugin.sh" --install-lumen no >/dev/null
  CODEX_HOME="$temp/codex-home" "$ROOT/setup/install_as_plugin.sh" --uninstall >/dev/null
  printf 'Real Codex plugin compatibility passed (no model run).\n'
else
  printf 'SKIP: codex CLI not installed\n'
fi

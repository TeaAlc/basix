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
router = (root / "skills/basix/SKILL.md").read_text()
assert "Follow all active instructions inside the managed" in router
assert "`basix:developer-instructions` block" in router
assert "does not replace or override them" in router
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
    "## Agent Memory",
    "Use `.basix/memory.toml` as the project's persistent agent memory",
    "read it exactly once at session start and exactly once after each context compaction",
    "create it when the first qualifying insight must be recorded",
    "Record durable insights likely to improve future sessions",
    "user instructions or durable clarifications",
    "Exclude secrets, credentials, personal data, transient task status, guesses",
    "Update or replace an existing entry rather than adding a duplicate or contradiction",
    "Use `version = 1` and zero or more `[[entries]]`",
    "except a `Subagent Insight` record also contains exactly `subagent_type`",
    "quoted ISO 8601 `YYYY-MM-DD` calendar date",
    "`User Instruction`, `Repository`, `Data Discovery`, `Tooling`, `Verification`, `Agent Collaboration`, `Workflow`, `Subagent Insight`, or `Other`",
    "exact role used for delegation",
    "Store every accepted subagent insight as a separate entry",
    "Evaluate every `final_result.data.subagent_insights` proposal",
    "Retain only useful insights supported by strong evidence",
    "no longer than three sentences",
    "no longer than 32 words in total",
    "Before every commit and context-compaction summary",
    "In a Git repository where `.basix` is not ignored",
    "Before a compaction summary, commit an eligible update after required verification",
    "Never commit an ignored `.basix` directory",
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
    "agent communication contract it references",
    "The spawn is invalid without this sentence",
    "Only `/root` starts generic subagents",
    "exact canonical contract inline",
    "visibly telling the user which agent receives it and why",
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

memory = tomllib.loads((root.parent / ".basix/memory.toml").read_text())
assert set(memory) == {"version", "entries"} and memory["version"] == 1
categories = {
    "User Instruction", "Repository", "Data Discovery", "Tooling",
    "Verification", "Agent Collaboration", "Workflow", "Subagent Insight", "Other",
}
def validate_memory_entry(entry):
    expected = {"date", "category", "insight"}
    if entry["category"] == "Subagent Insight":
        expected.add("subagent_type")
        assert isinstance(entry["subagent_type"], str) and entry["subagent_type"].strip()
    assert set(entry) == expected
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", entry["date"])
    assert entry["category"] in categories
    assert len(re.findall(r"\b[\w.-]+\b", entry["insight"])) <= 32
    assert len(re.findall(r"[.!?]+(?:\s|$)", entry["insight"])) <= 3
for entry in memory["entries"]:
    validate_memory_entry(entry)
validate_memory_entry({"date": "2026-01-01", "category": "Repository", "insight": "Legacy entry."})
validate_memory_entry({
    "date": "2026-01-01", "category": "Subagent Insight", "subagent_type": "default",
    "insight": "Strongly evidenced reusable lesson.",
})
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
    "Before any tool call or domain work, read the complete available basix router skill",
    "Only `/root` may start generic subagents",
    "exact canonical contract inline",
    "which agent receives the inline contract and why",
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
    "Contract 1.3 retains `report_started`",
    "subagent_insights",
    "automatic resumption at the next safe transition",
):
    assert phrase in agent_docs, phrase

heartbeat = (root / "skills/basix/references/agent-communication-contract.md").read_text()
assert "version=1.3" in heartbeat
assert "cycle_revision" in heartbeat
assert "`Berichtsbeginn an /root übermittelt.`" in heartbeat
assert "automatically resume the interrupted task" in heartbeat
assert "subagent_insights" in heartbeat and "at most 24 words" in heartbeat
assert re.search(r"first `status` 120 seconds after the plan and subsequent statuses every\s+120 seconds", heartbeat)
bootstrap_reference = (root / "skills/basix-agent-authoring/references/native-agent-bootstrap.md").read_text()
bootstrap_start = "<!-- basix-agent-authoring:bootstrap:start -->"
bootstrap_end = "<!-- basix-agent-authoring:bootstrap:end -->"
bootstrap = bootstrap_reference[
    bootstrap_reference.index(bootstrap_start):
    bootstrap_reference.index(bootstrap_end) + len(bootstrap_end)
]
for path in (root / "agents/native").glob("*.toml"):
    text = tomllib.loads(path.read_text())["developer_instructions"]
    assert text.count(bootstrap_start) == 1 and text.count(bootstrap_end) == 1, path
    actual = text[text.index(bootstrap_start):text.index(bootstrap_end) + len(bootstrap_end)]
    assert actual == bootstrap, path
    assert "basix-agent-authoring:contract:start" not in text, path
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

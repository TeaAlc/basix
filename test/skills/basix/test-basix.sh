#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
manifest = json.loads((root / "src/plugin/plugin.json").read_text())
assert manifest["name"] == "basix" and manifest["skills"] == "./skills/"
market = json.loads((root / "src/plugin/marketplace.json").read_text())
assert market["plugins"][0]["source"] == {"source": "local", "path": "./"}
for path in sorted((root / "src/skills").glob("*/SKILL.md")):
    match = re.search(r"(?m)^description:\s*(.+)$", path.read_text())
    assert match and match.group(1).strip().strip("\"'").startswith("Basix-Skill: "), path
# Double-quoted JSON strings are a YAML-compatible scalar subset. Validate the
# complete simple frontmatter without adding a third-party YAML dependency.
for name in ("basix", "basix-agent-authoring"):
    path = root / "src/skills" / name / "SKILL.md"
    frontmatter = path.read_text().split("---\n", 2)
    assert len(frontmatter) == 3 and not frontmatter[0], path
    fields = dict(line.split(": ", 1) for line in frontmatter[1].splitlines())
    assert set(fields) == {"name", "description"} and fields["name"] == name, path
    description = json.loads(fields["description"])
    assert isinstance(description, str) and description.startswith("Basix-Skill: "), path
router = (root / "src/skills/basix/SKILL.md").read_text()
router_flat = " ".join(router.split())
assert "sole runtime copy of Contract 2.0" in router
assert "maintaining, extending, testing, reviewing, or verifying" in router_flat
assert "[developing-basix.md](references/developing-basix.md) completely" in router_flat
assert "Do not load that reference merely because" in router_flat
development = (root / "src/skills/basix/references/developing-basix.md").read_text()
development_flat = " ".join(development.split())
assert (root / "src/scripts/run-quality-gates.sh").is_file()
assert (root / "src/scripts/quality-gates/basix.sh").is_file()
assert "## Risk-based quality gates" in development
assert "Fail closed when scope, base" in development_flat
assert "run-quality-gates.sh" in development_flat
assert "select tests" in development_flat and "changed components and their dependents" in development_flat
assert "Run the selected test paths explicitly" in development_flat
assert "report each command together with the change it covers" in development_flat
assert "`./test/verify-basix.sh` only when" in development_flat
assert "`./test/test-setup.sh` only when" in development_flat
assert "Every test that is started must" in development_flat and "finish successfully" in development_flat
for moved in ("src/agents", "repository-local `.codex/`", "reusable task workflows", "configure-tmux suite"):
    assert moved in development and moved not in router, moved
contract = (root / "src/skills/basix-subagent-management/references/agent-communication-contract.md").read_text()
assert "version=2.0" in contract and "communicates exclusively with its direct spawning parent" in contract
contract_flat = " ".join(contract.split())
for phrase in (
    "direct parent decides whether retained context is suitable",
    "fixes or context-related follow-up assignments",
    "updated goal, scope, files, ownership, permissions and acceptance criteria",
    "Identity and `task_name` remain fixed", "`cycle_revision + 1`",
    "Unrelated work or unsuitable context requires a fresh agent",
    "Each cycle has its own independently complete assignment and frozen target",
    "same eligible agent or a fresh agent under the reuse policy",
):
    assert phrase in contract_flat, phrase
for stale in ("confirms unchanged objective", "remediation verification require a fresh agent"):
    assert stale not in contract_flat, stale
assert not list((root / "src").glob("**/tests"))
management_path = root / "src/skills/basix-subagent-management/SKILL.md"
management = management_path.read_text()
assert not (root / "src/skills/basix/references/agent-communication-contract.md").exists()
assert "| Agent | Level |" in router and "| Agent | Level |" not in management
assert "sole spawn authority" in management
for phrase in (
    "before planning, messages, tools, or domain work",
    "If the router, management", "skill, or contract cannot be read, fail closed",
    "once per fresh context", "parent explicitly says it changed",
    "more than two substantive domain-tool calls", 'fork_turns="none"',
    "generic web access as a fallback", "stop extended discovery",
    "overlapping or unclear write ownership is inactive",
    "stop the verifier, discard its result", "`owned_targets`", "`mutation_window`",
):
    assert phrase in management, phrase
for name in ("basix-planning", "basix-adr", "basix-agent-memory"):
    assert f"[{name}](../{name}/SKILL.md)" in router, name
assert "[basix-planning](../basix-planning/SKILL.md)" in management
assert "[basix-agent-memory](../basix-agent-memory/SKILL.md)" in management
planning = (root / "src/skills/basix-planning/SKILL.md").read_text()
adr = (root / "src/skills/basix-adr/SKILL.md").read_text()
memory = (root / "src/skills/basix-agent-memory/SKILL.md").read_text()
assert "[basix-adr](../basix-adr/SKILL.md)" in planning
assert "[basix-agent-memory](../basix-agent-memory/SKILL.md)" in planning
adr_flat = " ".join(adr.split())
for phrase in ("Only `/root` presents the user-facing notice", "exclusively to its direct parent",
               "each parent independently evaluates", "never skipping a level",
               "explicit user confirmation is conveyed through the parent chain"):
    assert phrase in adr_flat, phrase
assert "basix-planning" not in adr
assert "at most 32 characters" in planning
assert "at most 24 words" in memory and "three sentences and 32 words" in memory
for path in (
    root / "src/skills/basix/SKILL.md", management_path,
    root / "src/skills/basix-agent-authoring/SKILL.md",
    *(root / "src/skills" / name / "SKILL.md" for name in
      ("basix-planning", "basix-adr", "basix-agent-memory")),
):
    for target in re.findall(r"\[[^]]+\]\(([^)]+)\)", path.read_text()):
        if "://" not in target and not target.startswith("#"):
            assert (path.parent / target).is_file(), (path, target)
print("ok - basix metadata, router, development guidance, contract, and test layout")
PY

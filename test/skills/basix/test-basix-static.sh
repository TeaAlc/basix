#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/src
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
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
    description = match.group(1).strip().strip('"\'') if match else ""
    assert description.startswith("Basix-Skill: "), path
    ui = path.parent / "agents/openai.yaml"
    if ui.exists():
        if path.parent.name == "configure-tmux":
            assert 'short_description: "Set up and troubleshoot tmux safely"' in ui.read_text(), ui
            continue
        match = re.search(r'(?m)^\s*short_description:\s*["\']?(Basix-Skill: .+?)["\']?\s*$', ui.read_text())
        assert match, ui
review_path = root / "skills/basix-experience"
review = (review_path / "SKILL.md").read_text()
review_flat = " ".join(review.split())
review_ui = (review_path / "agents/openai.yaml").read_text()
collector = review_path / "scripts/collect-token-usage.py"
assert collector.is_file()
assert re.search(r'\A---\nname: basix-experience\ndescription: ["\']Basix-Skill: ', review)
assert 'allow_implicit_invocation: true' in review_ui
assert 'display_name: "Basix Experience"' in review_ui
assert 'default_prompt: "Use $basix-experience ' in review_ui
for heading in ("Task overview", "Skill feedback", "Subagent feedback", "Token usage"):
    assert heading in review_flat, heading
for rating in (
    "not at all satisfied", "dissatisfied", "satisfied", "very satisfied",
    "extremely satisfied",
):
    assert f"`{rating}`" in review, rating
for phrase in (
    "one to three concrete", "at most 32 words", "Exclude `basix-experience` itself",
    "no prior skill use is evidenced", "no subagent use is evidenced",
    "structured telemetry", "input tokens", "reasoning tokens", "output tokens",
    "cached_tokens / input_tokens × 100", "round to one decimal place", "label the value as derived",
    "input tokens are exactly zero", "division by zero", "qualitatively",
    "exactly five concrete saving opportunities", "unique rank from 1 through 5",
    "single best next change", "Follow the language used by the user",
    "PYTHONDONTWRITEBYTECODE=1 python3", "collect-token-usage.py --format json",
    "must never block or abort the report", "status` is `ok` or `partial`",
    "aggregate metric only when that individual field is non-null",
    "`reasoning_output_tokens` to reasoning tokens",
    "`cached_input_tokens` to the cache counter", "never add, merge, or fill fields",
):
    assert phrase in review_flat, phrase
assert review.count("at most 32 words") == 2
assert "Do not infer hidden activity" in review_flat and "Do not count a skill merely because it was available" in review_flat
assert "Treat \"thin tokens\" as reasoning tokens" in review_flat

# Exercise the report contract with deterministic, localized scenario fixtures.
ratings = {
    "en": {"satisfied", "very satisfied", "extremely satisfied", "dissatisfied", "not at all satisfied"},
    "de": {"zufrieden", "sehr zufrieden", "überaus zufrieden", "nicht zufrieden", "gar nicht zufrieden"},
}
labels = {
    "en": {"unavailable": "not available", "derived": "derived"},
    "de": {"unavailable": "nicht verfügbar", "derived": "abgeleitet"},
}

def visible_skills(names):
    return [name for name in names if name != "basix-experience"]

def token_values(telemetry, language):
    unavailable = labels[language]["unavailable"]
    values = {
        "input": telemetry.get("input_tokens", unavailable),
        "reasoning": telemetry.get("reasoning_tokens", unavailable),
        "output": telemetry.get("output_tokens", unavailable),
    }
    cached = telemetry.get("cached_tokens")
    input_tokens = telemetry.get("input_tokens")
    if cached is None or input_tokens is None or input_tokens == 0:
        values["cache"] = unavailable
    else:
        values["cache"] = f"{cached / input_tokens * 100:.1f}% ({labels[language]['derived']})"
    return values

def recommendation_allowed(words, clear_value):
    return clear_value and len(words.split()) <= 32

scenarios = {
    "full_en": {
        "language": "en", "skills": ["basix", "skill-creator"],
        "agents": [("research_docs", "basix_researcher"), ("verify_result", "basix_verifier")],
        "telemetry": {"input_tokens": 200, "reasoning_tokens": 0, "output_tokens": 80, "cached_tokens": 50},
    },
    "partial_de": {
        "language": "de", "skills": ["basix"], "agents": [],
        "telemetry": {"input_tokens": 100, "cached_tokens": 25},
    },
    "none_en": {"language": "en", "skills": [], "agents": [], "telemetry": {}},
    "self_only_de": {
        "language": "de", "skills": ["basix-experience"], "agents": [], "telemetry": {},
    },
    "zero_input_en": {
        "language": "en", "skills": [], "agents": [],
        "telemetry": {"input_tokens": 0, "reasoning_tokens": 0, "output_tokens": 0, "cached_tokens": 0},
    },
}

full = scenarios["full_en"]
assert visible_skills(full["skills"]) == ["basix", "skill-creator"]
assert full["agents"] == [("research_docs", "basix_researcher"), ("verify_result", "basix_verifier")]
assert token_values(full["telemetry"], "en") == {
    "input": 200, "reasoning": 0, "output": 80, "cache": "25.0% (derived)",
}
partial = token_values(scenarios["partial_de"]["telemetry"], "de")
assert partial == {"input": 100, "reasoning": "nicht verfügbar", "output": "nicht verfügbar", "cache": "25.0% (abgeleitet)"}
assert visible_skills(scenarios["none_en"]["skills"]) == [] and scenarios["none_en"]["agents"] == []
assert visible_skills(scenarios["self_only_de"]["skills"]) == []
assert token_values(scenarios["zero_input_en"]["telemetry"], "en") == {
    "input": 0, "reasoning": 0, "output": 0, "cache": "not available",
}
assert ratings["en"] == {"satisfied", "very satisfied", "extremely satisfied", "dissatisfied", "not at all satisfied"}
assert ratings["de"] == {"zufrieden", "sehr zufrieden", "überaus zufrieden", "nicht zufrieden", "gar nicht zufrieden"}
assert recommendation_allowed("Add a focused telemetry collector for future session reviews.", True)
assert not recommendation_allowed("Omit this idea because no additional skill would clearly improve the next comparable session.", False)
assert not recommendation_allowed(" ".join(["word"] * 33), True)
for language, headings in {
    "en": ("Task overview", "Skill feedback", "Subagent feedback", "Token usage"),
    "de": ("Aufgabenübersicht", "Skill-Feedback", "Subagenten-Feedback", "Token-Nutzung"),
}.items():
    fixture = "\n".join(f"# {heading}" for heading in headings)
    assert [line.removeprefix("# ") for line in fixture.splitlines()] == list(headings), language
savings_fixture = [(rank, "cause", "action", "effect") for rank in range(1, 6)]
assert len(savings_fixture) == 5 and [row[0] for row in savings_fixture] == [1, 2, 3, 4, 5]
router = (root / "skills/basix/SKILL.md").read_text()
router_flat = " ".join(router.split())
development_path = root / "skills/basix/references/developing-basix.md"
assert development_path.is_file()
development = development_path.read_text()
development_flat = " ".join(development.split())
quality_runner = root / "scripts/run-quality-gates.sh"
quality_profile = root / "scripts/quality-gates/basix.sh"
assert quality_runner.is_file() and quality_profile.is_file()
assert "## Risk-based quality gates" in development
for phrase in (
    "smallest gate set proven sufficient",
    "failure surface",
    "syntax or format checks",
    "frozen independent review",
    "Never omit a gate merely because it is slow",
    "Fail closed when scope, base",
    "independent read-only gates concurrently",
    "recoverable log directory",
    "run-quality-gates.sh",
    "quality-gates/",
    "test-basix-static.sh",
    "test-setup-support.sh",
    "verify-basix.sh",
    "test-setup.sh",
    "frozen review evidence",
    "--impact configure-tmux",
    "release-gate-podman.sh",
    "Quality gates exclude `.basix/` entirely",
    "filter them from automatic change discovery",
    "reject explicit `.basix/` paths",
    "explicitly provide read-only paths to the plan or ADR files",
    "the verifier reads only those named context files",
    "the parent decides which paths are relevant",
):
    assert phrase in development_flat, phrase
standard_aggregate = (root.parent / "test/verify-basix.sh").read_text()
assert "test/skills/configure-tmux/test-configure-tmux-suite.sh" not in standard_aggregate
assert "test/scripts/test-run-quality-gates.sh" in standard_aggregate
assert "Follow all active instructions inside the managed" in router
assert "`basix:developer-instructions` block" in router
assert "does not replace or override them" in router
assert "In an installed skill, resolve skill-local scripts" in router
assert "Write all technical content in English" in router
assert "language of the current conversation" in router
assert "maintaining, extending, testing, reviewing, or verifying" in router_flat
assert "[developing-basix.md](references/developing-basix.md) completely" in router_flat
assert "Do not load that reference merely because" in router_flat
for phrase in (
    "`<Basix-Repo>/src/agents`", "`<Basix-Repo>/src/skills`",
    "`<Basix-Repo>/src/scripts`", "Exclude repository-local `.codex/` and",
    "`.agents/` runtime configuration from", "Agents must not modify either directory directly",
    "Basix installers may write there", "installer tests use isolated temporary targets",
    "reusable task workflows", "skill-specific scripts, references, and assets",
    "shared launchers", "native agent definitions canonical", "domain workflow",
    "Update the relevant documentation", "changed components and their dependents",
    "Run the selected test paths explicitly", "report each command together with the change it covers",
    "`./test/verify-basix.sh` only when", "`./test/test-setup.sh` only when",
    "Every test that is started must finish successfully",
    "configure-tmux suite is excluded from",
    "only when an explicit plan changes the configure-tmux skill",
):
    assert phrase in development_flat, phrase
for moved in (
    "`<Basix-Repo>/src/agents`", "repository-local `.codex/`", "reusable task workflows",
    "skill-specific scripts", "shared launchers", "native agent definitions canonical",
    "domain workflow", "Update the relevant documentation", "changed components and their dependents",
    "verify-basix.sh", "test-setup.sh", "configure-tmux suite",
):
    assert moved not in router, moved
for phrase in ("Agent level governs coordination", "`/root` | principal",
               "`basix_pager` | senior", "`basix_verifier` | senior",
               "`basix_file_explorer` | junior", "`basix_researcher` | junior",
               "`basix_miraculix` | junior",
               "agent_level: junior", "non-root principal", "never spawn generic agents"):
    assert phrase in router, phrase
assert "| Agent | Level |" in router and "| Children |" not in router
router_level_rows = re.findall(
    r"(?m)^\| `([^`]+)` \| (junior|senior|principal) \|$", router
)
router_levels = dict(router_level_rows)
assert len(router_level_rows) == len(router_levels), router_level_rows
native_levels = {}
for path in sorted((root / "agents/native").glob("*.toml")):
    lines = path.read_text().splitlines()
    assert lines[0] == "# basix-agent-authoring:metadata:start", path
    metadata_end = lines.index("# basix-agent-authoring:metadata:end")
    assert metadata_end in (2, 3), path
    agent = tomllib.loads(path.read_text())
    metadata_text = "\n".join(
        line.removeprefix("# ")
        for line in lines[1:metadata_end]
        if line.startswith("# metadata = ")
    )
    metadata = tomllib.loads(metadata_text)["metadata"]
    native_levels[agent["name"]] = metadata["level"]
    assert agent["description"].startswith("Basix-Agent: "), path
    assert agent["developer_instructions"].lstrip().startswith(
        f"You are a {metadata['level']} Basix agent."
    ), path
    for legacy in (
        "Do not spawn subagents.",
        "You may spawn only `basix_file_explorer` and `basix_researcher`.",
        "Do not spawn generic agents, senior agents, or principals.",
        "Do not spawn principals.",
    ):
        assert legacy not in agent["developer_instructions"], (path, legacy)
assert router_levels == {"/root": "principal", **native_levels}
pager_path = root / "agents/native/basix-pager.toml"
pager = tomllib.loads(pager_path.read_text())
assert pager["name"] == "basix_pager"
assert pager["model"] == "gpt-6-luna" and pager["model_reasoning_effort"] == "xhigh"
assert pager["sandbox_mode"] == "workspace-write"
assert "task_profile" in pager["developer_instructions"]
for profile in ("ui_ux", "frontend", "backend_web", "fullstack", "integration"):
    assert f"`{profile}`" in pager["developer_instructions"], profile
assert "## Result evidence" in pager["developer_instructions"]
assert "After any correction, rerun targeted and complete relevant gates." in pager["developer_instructions"]
for stale in ("fresh, terminal worker", "New work receives a fresh pager", "Any fix stays within this assignment"):
    assert stale not in pager["developer_instructions"], stale
assert ".basix/contracts/<chain-id>.md" in pager["developer_instructions"]
verifier_path = root / "agents/native/basix-verifier.toml"
verifier = tomllib.loads(verifier_path.read_text())
assert verifier["name"] == "basix_verifier"
assert verifier["model"] == "gpt-6-luna" and verifier["model_reasoning_effort"] == "xhigh"
assert verifier["sandbox_mode"] == "read-only"
for phrase in (
    "immutable", "inconclusive", "fork_turns=\"none\"", "spawning parent", "write freeze",
    "explicit read-only paths to plan or ADR files",
    "The parent decides which context files are relevant",
    "Never scan `.basix/`",
    "evidence context rather than mutable",
):
    assert phrase in verifier["developer_instructions"], phrase
for phrase in ("Fingerprint", "target drift", "cycle_revision", "followup_task", "send exactly one `final_result`"):
    assert phrase not in verifier["developer_instructions"], phrase
assert not (root / "agents/exec").exists()
PY
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
import re
import sys
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
# Reverse only authorized source research/ticket startup/cron additions,
# the reread clarification, scoped checkpoint exception, and four activation lines.
# Prove all other bytes remain unchanged.
# The fixed digest matches the pre-source-memory HEAD baseline; installed tests need no Git.
import hashlib
instruction_bytes = (root / "setup/developer_instruction.md").read_bytes()
checkpoint_exception = "- Exception to the preceding commit timing rule: `/root` may create a Conventional Commit checkpoint on an assigned feature branch after its writer is inactive, its local checks pass and its result is accepted. Commit only that frozen, verified scope; unrelated checks may continue. This grants no child commit authority and does not relax final completion checks. Follow `basix-planning`'s parallel Git reference for isolation, integration and target updates.\n".encode()
assert instruction_bytes.count(checkpoint_exception) == 1
baseline_bytes = instruction_bytes.replace(checkpoint_exception, b"", 1)
ticket_startup = "## Ticket management\n\n- At session start and after each context compaction, check if in .basix/tickets/open or .basix/tickets/failed are files, when the are present. If there are files, load the `basix-ticket-management` skill and silently inspect the files. Report relevant action needs; follow the skill's authorization and retry rules.\n\n".encode()
assert instruction_bytes.count(ticket_startup) == 1
baseline_bytes = baseline_bytes.replace(ticket_startup, b"", 1)
source_research = '## Information-source research\n\n- Agents researching information sources (websites, documentation, articles, publications) must read and follow the complete `basix-source-memory` skill before research; source-code inspection alone does not trigger it.\n- This includes subagents; the spawning parent must explicitly mandate the skill in every such assignment.\n- Read-only agents return observations and research coverage to their parent for persistence.\n\n'.encode()
assert instruction_bytes.count(source_research) == 1
assert len(source_research.decode().split()) <= 64
assert len([line for line in source_research.decode().splitlines() if line.startswith("- ")]) == 3
baseline_bytes = baseline_bytes.replace(source_research, b"", 1)
cron_trigger_rule = '- Cron jobs that start an agent harness or trigger agents must identify the trigger to the agent by prepending a marker to the prompt, for example `(Triggered by CronJob)`. Use `(Triggered by <event> [Flags])` with the actual event name; optional flags are expressed as tags, for example `(Triggered by CronJob [nightly] [maintenance])`.\n'.encode()
assert instruction_bytes.count(cron_trigger_rule) == 1
baseline_bytes = baseline_bytes.replace(cron_trigger_rule, b"", 1)
original_reread_rule = '- Do not reread skill, agent, or reference instructions already in context unless the user explicitly requests it. You must reread skills after a kontext compact, if you need them again.\n'.encode()
clarified_reread_rule = '- Do not reread skill, agent, or reference instructions already in context unless the user explicitly requests it or the direct parent explicitly states during a continuation that the source has changed. After context compaction, reread required instructions before using them.\n'.encode()
assert instruction_bytes.count(clarified_reread_rule) == 1
baseline_bytes = baseline_bytes.replace(clarified_reread_rule, original_reread_rule, 1)
assert (root / "skills/basix-ticket-management/SKILL.md").is_file()
for heading, skill, suffix in (
    ("Planning", "basix-planning", ""),
    ("Architecture Decision Records (ADRs)", "basix-adr", ""),
    ("Agent Memory", "basix-agent-memory", ""),
    ("Basix agent spawning", "basix-subagent-management", " (Read it when you need it, not upfront)"),
):
    pattern = rb"(?ms)^## " + re.escape(heading.encode()) + rb"\n.*?(?=^## |^<!-- basix:developer-instructions:end -->)"
    section = re.search(pattern, baseline_bytes).group(0)
    replacement = f"- Skill: `{skill}` (its complete `SKILL.md`).{suffix}".encode()
    assert section.count(replacement) == 1, heading
    assert (root / "skills" / skill / "SKILL.md").is_file(), skill
    original = f"- TODO: Add skillname{suffix}".encode()
    baseline_bytes = baseline_bytes.replace(section, section.replace(replacement, original), 1)
assert b"TODO: Add skillname" not in instruction_bytes
assert hashlib.sha256(baseline_bytes).hexdigest() == "6db1bb7097aa51fe35d90107686237a87972e8379b75f93ae7dd64120ebe83ff", "developer instructions changed outside authorized TODO spans, source research/ticket startup additions, cron trigger rule, reread clarification and scoped checkpoint exception"
# Validate the documented ticket data examples, not just skill discovery.
import json
ticket_skill = (root / "skills/basix-ticket-management/SKILL.md").read_text()
ticket_examples = [json.loads(body) for body in re.findall(r"```json\n(.*?)\n```", ticket_skill, re.S)]
assert len(ticket_examples) == 3
systems, metadata, draft = ticket_examples
assert len(systems) >= 2
for system, mapping in systems.items():
    assert re.fullmatch(r"[a-z0-9-]{1,16}", system)
    assert set(mapping) == {"service", "instance", "scope", "access"}
    assert all(isinstance(value, str) for value in mapping.values())
assert set(metadata) == {"id", "datetime", "url", "title", "hints"}
assert isinstance(metadata["id"], str) and len(metadata["title"]) <= 32
assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", metadata["datetime"])
import uuid
assert uuid.UUID(draft["id"]).version == 4 and str(uuid.UUID(draft["id"])) == draft["id"]
assert {"id", "datetime", "title", "hints", "request", "error", "initial_attempt", "retries"} <= set(draft)
assert isinstance(draft["request"], dict) and len(draft["retries"]) <= 5
for number, attempt in enumerate([draft["initial_attempt"], *draft["retries"]]):
    assert set(attempt) == {"attempt", "started_at", "finished_at", "outcome", "error"}
    assert attempt["attempt"] == number
    assert attempt["outcome"] in {"pending", "failed", "uncertain", "confirmed"}
for record in (metadata, draft):
    assert isinstance(record["hints"], list)
    assert all(isinstance(hint, str) for hint in record["hints"])
for doc in (root.parent / "README.md", root / "docs/skills.md"):
    assert "basix-ticket-management" in doc.read_text()

instructions = (root / "setup/developer_instruction.md").read_text()
assert instructions.count("<!-- basix:developer-instructions:start -->") == 1
assert instructions.count("<!-- basix:developer-instructions:end -->") == 1
policy = instructions.split("<!-- basix:developer-instructions:start -->", 1)[1].split(
    "<!-- basix:developer-instructions:end -->", 1
)[0]
# Compose authoritative workflow skills with retained developer boundaries.
def replace_policy_section(policy, heading, source):
    pattern = rf"(?ms)^## {re.escape(heading)}\n.*?(?=^## )"
    section = re.search(pattern, policy).group(0)
    if heading == "Agent Memory":
        retained = "\n".join(line for line in section.splitlines() if line.startswith("- `.basix/memory.toml`") or line.startswith("- Read it exactly once"))
        source = retained + "\n" + source
    return policy.replace(section, "## " + heading + "\n\n" + source.strip() + "\n\n")
for heading, filename in (
    ("Planning", "../skills/basix-planning/SKILL.md"),
    ("Architecture Decision Records (ADRs)", "../skills/basix-adr/SKILL.md"),
    ("Agent Memory", "../skills/basix-agent-memory/SKILL.md"),
):
    policy = replace_policy_section(policy, heading, (root / "setup" / filename).read_text())
policy += (root / "skills/basix/SKILL.md").read_text()
policy += (root / "skills/basix-subagent-management/SKILL.md").read_text()
for phrase in ("`/root` is the fixed principal", "sets `agent_level` in the assignment", "without asking again",
               "defaults to `agent_level: junior`", "never spawns another principal"):
    assert phrase in " ".join(policy.split()), phrase
memory_section = re.search(r"(?ms)^## Agent Memory\n.*?(?=^## )", policy).group(0)
assert len(memory_section) <= 4200, len(memory_section)
conventions_section = re.search(r"(?ms)^## Basix conventions\n.*?(?=^## )", policy).group(0)
for removed in (
    "Whenever invoking Python, set `PYTHONDONTWRITEBYTECODE=1`",
    "Order every Basix-managed plan to maximize input-token efficiency",
    "Prioritize early insights that shrink later context",
):
    assert removed not in conventions_section, removed
for phrase in (
    "Run Python with `PYTHONDONTWRITEBYTECODE=1`",
    "canonical RFC 4122 UUID v4",
    "cryptographically secure system source",
    "pass it as `client_id` on every tool call",
    "Reuse the same ID for related session calls",
    "give it to a subagent only when deliberately sharing that session capability",
    "never log it or substitute `default`, a `session_id`, or a server-generated placeholder",
):
    assert phrase in conventions_section, phrase
# Check the authoritative entrypoint across its own headings, not just the
# first subsection embedded in the composed developer-policy view.
planning_section = (root / "skills/basix-planning/SKILL.md").read_text()
planning_flat = " ".join(planning_section.split())
assert policy.count("## Planning") == 1
assert policy.index("## Basix conventions") < policy.index("## Planning") < policy.index("## Agent Memory")
phase_fields = ("**Goal:**", "**Work:**", "**QS:**", "**Learnings:**")
positions = [planning_section.index(field) for field in phase_fields]
assert positions == sorted(positions)
for requirement in (
    "one explicit overall goal", "self-contained", "stated dependencies",
    "**Task 1:** through **Task n:**", "topological", "Concrete completion checks",
    "Empty initially", "entire phase QS succeeds", "findings useful to later phases",
    "never placeholders such as `Pending`", "memory.toml", "basix-agent-memory",
    "input-token efficiency", "correctness, safety", "mandatory dependencies",
    "(Subagent Task: <subagent_type>)", "at most 32 characters",
    "10 million expected input tokens", "whether to compact after every phase",
    "findings, decisions, dependencies and discovery results",
    ".basix/plans/<stem>-NNN.md", "only direct files", ".basix/plans/archive/",
    "ignoring other nested directories", "at least three digits",
    "`001`, `010`, `999`, `1000`", "never `000`, `01`, `0001`",
    "logical stem", "independently per stem", "highest valid suffix plus one",
    "both directories", "Never reuse a lower number or overwrite a path",
    "unsuffixed and malformed legacy files", "without renaming or counting them",
    "create no new unsuffixed plan", "After each phase, update remaining work",
    "overall goal", "completed/replaced plans", "exact numbered basenames",
):
    assert requirement in planning_flat, requirement
assert "initially `Pending`" not in planning_section

adr_section = re.search(r"(?ms)^## Architecture Decision Records \(ADRs\)\n.*?(?=^## )", policy).group(0)
assert policy.count("## Architecture Decision Records (ADRs)") == 1
assert policy.index("## Planning") < policy.index("## Architecture Decision Records (ADRs)") < policy.index("## Agent Memory")
for phrase in (
    "Before planning or implementation, read the active index `.basix/adrs/ADR.md`",
    "load only the active ADRs relevant to the work",
    "Active ADRs are binding",
    "durable decision that is difficult to reverse",
    "crosses subsystem boundaries",
    "long-term architecture, security, data, or workflow commitment",
    "`.basix/adrs/ADR_NNNN_<descriptive-name>.md`",
    "descriptive English kebab-case name",
    "globally increasing number across active and archived ADRs",
    "zero-padded to at least four digits",
    "never reuse a number",
    "`Status`, `Context`, `Decision`, and `Consequences`",
    "including Markdown and whitespace",
    "512 Unicode characters",
    "`.basix/adrs/ADR.md` lists only active ADRs",
    "`.basix/adrs/archive/ADR.md` lists only archived ADRs",
    "states its status or successor",
    "index files are exempt from the 512-character limit",
    "Editorial corrections may update an existing ADR",
    "A new or changed decision requires a new ADR",
    "Superseding, merging, or archiving without replacement requires prior user confirmation",
    "successor must name the ADR it supersedes",
    "allocate the next number to the new ADR",
    "name every merged ADR",
    "make only the new ADR binding",
    "move all source ADRs to the archive",
    "Only the mandatory `Merged ADRs: ...` line in a merge ADR is exempt",
    "Give every archived ADR an appropriate status",
    "update both indexes atomically",
    "pause the affected implementation",
    "Only `/root` presents the user-facing notice",
    "exclusively to its direct parent",
    "each parent independently evaluates",
    "never skipping a level",
    '`<div style="color:red">…</div>`',
    "so the user need not read the ADR",
    "binding decision, planned deviation, exact conflict, and impact",
    "comply with the ADR",
    "replace it with a user-confirmed successor",
    "replan the scope to avoid the conflict",
    "Resume conflicting implementation only after explicit user confirmation",
    "Agents create `.basix/adrs/` and its indexes when the first ADR is required",
    "Basix installers must not create the directory, templates, or an initial ADR",
):
    assert adr_section.count(phrase) == 1, phrase
assert adr_section.count("description of at most 64 Unicode characters") == 2

def validate_adr(body, merged_line=None):
    """Model required fields and Unicode character limits."""
    for field in ("Status", "Context", "Decision", "Consequences"):
        assert re.search(rf"(?m)^## {field}$", body), field
    measured = body
    if merged_line is not None:
        assert merged_line.startswith("Merged ADRs: ")
        assert body.count(merged_line) == 1
        measured = body.replace(merged_line, "", 1)
    assert len(measured) <= 512

base_adr = "## Status\nActive\n## Context\nC\n## Decision\nD\n## Consequences\n"
validate_adr(base_adr + "ü" * (512 - len(base_adr)))
try:
    validate_adr(base_adr + "ü" * (513 - len(base_adr)))
except AssertionError:
    pass
else:
    raise AssertionError("ADR Unicode character limit must be enforced")
merge_line = "Merged ADRs: ADR_0001_a.md, ADR_0002_b.md"
validate_adr(base_adr + "x" * (512 - len(base_adr)) + merge_line, merge_line)

adr_name = re.compile(r"^ADR_(\d{4,})_([a-z0-9]+(?:-[a-z0-9]+)*)\.md$")
assert adr_name.fullmatch("ADR_0001_descriptive-name.md")
assert not adr_name.fullmatch("ADR_001_Bad_Name.md")
active_numbers = {1, 4}
archived_numbers = {2, 3}
assert max(active_numbers | archived_numbers) + 1 == 5
active_entries = [("ADR_0001_a.md", "ü" * 64)]
archive_entries = [("ADR_0002_b.md", "Superseded by ADR_0004", "x" * 64)]
assert all(len(description) <= 64 for _, description in active_entries)
assert all(len(description) <= 64 and status for _, status, description in archive_entries)
assert not ({name for name, _ in active_entries} & {name for name, _, _ in archive_entries})

def next_plan_basename(stem, active_files, archived_files):
    """Model direct-file scanning and canonical highest-plus-one allocation."""
    suffixes = []
    occupied = set(active_files) | set(archived_files)
    pattern = re.compile(rf"^{re.escape(stem)}-(\d+)\.md$")
    for pathname in occupied:
        if "/" in pathname:
            continue
        basename = pathname
        match = pattern.fullmatch(basename)
        if not match:
            continue
        suffix = match.group(1)
        if (
            len(suffix) >= 3
            and int(suffix) >= 1
            and suffix == str(int(suffix)).zfill(3)
        ):
            suffixes.append(int(suffix))
    next_number = max(suffixes, default=0) + 1
    candidate = f"{stem}-{next_number:03d}.md"
    assert candidate not in occupied
    return candidate

release_active = [
    "release-gate-001.md", "release-gate-003.md", "release-gate.md",
    "release-gate-000.md", "release-gate-01.md", "release-gate-0001.md",
    "nested/release-gate-998.md",
]
release_archive = [
    "release-gate-004.md", "unrelated-099.md", "nested/release-gate-999.md",
]
assert next_plan_basename("release-gate", release_active, release_archive) == "release-gate-005.md"
assert next_plan_basename(
    "new-plan", ["new-plan.md", "new-plan-000.md", "new-plan-01.md", "new-plan-0001.md"], []
) == "new-plan-001.md"
assert next_plan_basename("unrelated", ["unrelated-002.md"], []) == "unrelated-003.md"
assert next_plan_basename("release-gate", ["release-gate-999.md"], []) == "release-gate-1000.md"

def move_to_archive(active_files, archived_files, basename):
    assert basename in active_files
    if basename in archived_files:
        raise FileExistsError(basename)
    return [name for name in active_files if name != basename], archived_files + [basename]

remaining, archived = move_to_archive(
    ["release-gate-005.md"], ["release-gate-004.md"], "release-gate-005.md"
)
assert remaining == [] and archived[-1] == "release-gate-005.md"
try:
    move_to_archive(["release-gate-005.md"], ["release-gate-005.md"], "release-gate-005.md")
except FileExistsError:
    pass
else:
    raise AssertionError("archive collision must not overwrite an existing path")
assert "Run Python with `PYTHONDONTWRITEBYTECODE=1`" in policy
for phrase in (
    "## Basix conventions",
    "Do not use gender-inclusive language",
    "Before using a Basix agent or specialized Basix skill, read the complete `basix` router skill",
    "Before spawning a Basix agent, read the complete communication contract referenced by the router",
    "Do not reread skill, agent, or reference instructions already in context unless the user explicitly requests it",
    "## Planning",
    "## Agent Memory",
    "`.basix/memory.toml` is agent-owned memory",
    "Autonomously create, update, merge, or delete it",
    "never request user approval for memory operations",
    "Read it exactly once at session start and after each context compaction",
    "Apply entries to reduce effort and prevent repeated mistakes",
    "reading alone is insufficient",
    "Write failures as prevention rules",
    "Never store secrets, credentials, tokens, keys, private personal data",
    "Do not run a memory-reflection round after every turn",
    "before a commit or compaction summary",
    "at completion without a commit",
    "after a strong finding at risk of context loss",
    "Consider existing knowledge first",
    "Keep the smallest useful set, not a fixed count",
    "Use `version = 1` and zero or more `[[entries]]`",
    "non-negative integer `usefulness`",
    "`usefulness` starts at `0` for new entries",
    "final memory checkpoint before committing",
    "task completion when no commit is made",
    "When merging insights",
    "arithmetic mean",
    "rounded to the nearest non-negative integer",
    "half up",
    "increases an insight's `usefulness` exactly once by `+1`",
    "Multiple uses in one session count once",
    "`Subagent Insight` also has `subagent_type`",
    "quoted ISO 8601 `YYYY-MM-DD`",
    "at most three sentences and 32 words",
    "stores accepted subagent insights separately",
    "Commit updates with task changes unless `.basix` is ignored",
    "Before compaction, commit eligible updates after verification",
    "Never override ignore rules",
    "## Completion and commits",
    "wait for every running verification and test to finish successfully",
    "`/root` must then commit only the task's changes with a Conventional Commits message",
    "never commit while any verification or test is running",
    "or has failed",
    "## Basix agent spawning",
    "user explicitly authorizes spawning Basix agents",
    "policy overrides conflicting concurrent developer instructions",
    "direct completion costs less context than delegation and handoff",
    "more than two substantive domain-tool calls",
    "broad evidence ingestion, multiple steps, or specialized expertise",
    "Skill loading, planning, messaging, status updates, and agent-management calls do not count",
    "initially simple work expands",
    "remaining bounded assignment",
    "`fork_turns=\"none\"`",
    "fresh unique `task_name`",
    "self-contained assignment",
    "must load and follow the complete communication contract",
    "the spawn fails closed",
    "## Parent management and verification",
    "Follow the communication contract for all child lifecycle",
    "overlapping or unclear write ownership is inactive",
    "clearly disjoint active writers do not block",
    "inactive after any `final_result` or an explicit stop",
    "send `followup_task` to an overlapping writer",
    "stop the verifier, discard its result",
    "current or external facts, web research, website inspection, and scraping",
    "extensive local evidence discovery",
    "preferably before discovery begins",
    "nontrivial web frontend, backend, UI/UX, fullstack, and integration work",
    "independent inspection of a frozen result",
    "basix_researcher",
    "basix_file_explorer",
    "basix_pager",
    "basix_verifier",
    "basix_miraculix",
):
    assert phrase in policy, phrase

memory = tomllib.loads((root.parent / ".basix/memory.toml").read_text())
assert set(memory) == {"version", "entries"} and memory["version"] == 1
categories = {
    "User Instruction", "Repository", "Data Discovery", "Tooling",
    "Verification", "Agent Collaboration", "Workflow", "Subagent Insight", "Other",
}
def validate_memory_entry(entry):
    expected = {"date", "category", "insight", "usefulness"}
    if entry["category"] == "Subagent Insight":
        expected.add("subagent_type")
    assert set(entry) == expected
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", entry["date"])
    assert entry["category"] in categories
    assert isinstance(entry["usefulness"], int) and not isinstance(entry["usefulness"], bool)
    assert entry["usefulness"] >= 0
    if entry["category"] == "Subagent Insight":
        assert isinstance(entry["subagent_type"], str) and entry["subagent_type"].strip()
    assert len(re.findall(r"\b[\w.-]+\b", entry["insight"])) <= 32
    assert len(re.findall(r"[.!?]+(?:\s|$)", entry["insight"])) <= 3
for entry in memory["entries"]:
    validate_memory_entry(entry)
verifier_insights = [
    entry for entry in memory["entries"]
    if entry.get("subagent_type") == "basix_verifier"
]
assert any("Copy-tree uninstall" in entry["insight"] for entry in verifier_insights)
workflow_insights = [entry for entry in memory["entries"] if entry["category"] == "Workflow"]
assert any("focused negative tests" in entry["insight"] for entry in workflow_insights)
validate_memory_entry({
    "date": "2026-01-01", "category": "Repository", "insight": "Legacy entry.", "usefulness": 0,
})
validate_memory_entry({
    "date": "2026-01-01", "category": "Subagent Insight", "subagent_type": "basix_file_explorer",
    "insight": "Strongly evidenced reusable lesson.", "usefulness": 3,
})
for invalid in (
    {"date": "2026-01-01", "category": "Repository", "insight": "Missing counter."},
    {"date": "2026-01-01", "category": "Repository", "insight": "Boolean counter.", "usefulness": True},
    {"date": "2026-01-01", "category": "Repository", "insight": "Negative counter.", "usefulness": -1},
    {"date": "2026-01-01", "category": "Repository", "insight": "Float counter.", "usefulness": 1.5},
    {"date": "2026-01-01", "category": "Repository", "insight": "String counter.", "usefulness": "1"},
):
    try:
        validate_memory_entry(invalid)
    except (AssertionError, KeyError):
        pass
    else:
        raise AssertionError("invalid usefulness shape accepted")
for removed in (
    "Subagent confirmations",
    "task_profile",
    "intermediate_result",
    ".basix/contracts/",
    "Adaptive pager selection and lifecycle",
    "Read-only verification lifecycle",
    "before the third filesystem-exploration tool call",
    "works primarily as planner, coordinator, and integrator",
    "generic subagent",
    "communicate directly with `/root`",
    "relay child bootstrap failures",
):
    assert removed not in policy, removed

router = (root / "skills/basix/SKILL.md").read_text()
management = (root / "skills/basix-subagent-management/SKILL.md").read_text()
skill = router + management
for phrase in (
    "## Basix agent spawning",
    "## Required subagent management",
    "sole runtime copy of Contract 2.0",
    "direct completion costs less context than delegation and handoff",
    "more than two substantive domain-tool calls",
    'fork_turns="none"',
    "unique `task_name`",
    "generic web access",
    "derive spawn authority",
    "Follow the communication contract",
    "strongly recommended under extreme uncertainty",
    "`basix_miraculix`",
):
    assert phrase in skill, phrase
for removed in ("generic subagent", "Native and generic", "communicate directly with `/root`", "Relay assignments and results"):
    assert removed not in skill, removed

architecture = (root / "docs/architecture.md").read_text()
for phrase in (
    "explicit delegation authority",
    "cost-aware Root boundary",
    "mandatory role routing",
    "native spawning rules",
    "every Basix-managed plan to maximize input-token efficiency",
    "early insights should shrink later context",
    "correctness, safety, and mandatory dependencies remain authoritative",
    "Contract 2.0 exclusively owns",
    "ADR governance",
    "read the project-owned active ADR index",
    "Installers never create that directory, an ADR template, or an initial ADR",
):
    assert phrase in architecture, phrase

installation = (root / "docs/installation.md").read_text()
assert "Installers never create `.basix/adrs/`, ADR" in installation
assert "agents create the directory and indexes only when" in installation
for installer in (root / "setup/install_as_plugin.sh", root / "setup/install_for_project.sh"):
    installer_text = installer.read_text()
    assert ".basix/adrs" not in installer_text and "ADR_" not in installer_text, installer

description_requirements = {
    "basix-file-explorer.toml": ("file explorer", "read-only", "assign"),
    "basix-researcher.toml": ("researcher", "read-only", "assign"),
    "basix-pager.toml": ("pager", "workspace-writing", "authorized"),
    "basix-verifier.toml": ("verifier", "read-only", "frozen"),
    "basix-miraculix.toml": ("short-answer consultant", "read-only", "goal"),
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
    "| Highly complex | `gpt-6-luna`, `xhigh` |",
    "| Exceptional | `gpt-6-luna`, `max` |",
    "gpt-6-luna` with `xhigh` reasoning",
    "bug hunting plus bug fixing",
    "coordinating subagents",
    "workspace-write",
    "explicit-sandbox-override",
    "Every other native Basix",
    "agent remains `read-only`",
    "`basix_verifier` performs difficult source-code",
    "Choose `max` only for rare Exceptional assignments",
):
    assert phrase in classification, phrase

agent_docs = " ".join((root / "docs/agents.md").read_text().split())
for phrase in (
    "Before planning or implementation, agents read `.basix/adrs/ADR.md`",
    "globally increasing numbers across active and archived records",
    "installers never create ADR artifacts",
    "pause for explicit user confirmation",
    "Verification assignment and lifecycle",
    "basix_verifier",
    "immutable",
    "verification_id:",
    "mutation_window:",
    "relevant writers inactive before spawn",
    "write freeze held through verifier completion",
    "unknown or overly broad ownership counts as possible overlap",
    "first stops the verifier, discards its result",
    "report_strictness:",
    "fresh verifier",
    "Manual pager smoke scenarios",
    "run-pager-smoke.sh",
    "for profile in ui_ux frontend backend_web fullstack integration",
    "direct spawning parent",
    "never forwards a child message automatically",
    "Contract 2.0 is the sole source for runtime communication",
    "explicit read-only paths to plan or ADR files",
    "the parent chooses those paths",
    "never scans `.basix/`",
    "Quality gates remain forbidden from inspecting `.basix/`",
    "basix_miraculix",
    "gpt-6-astra",
    "strongly recommended under extreme uncertainty",
    "Das weiß ich nicht",
):
    assert phrase in agent_docs, phrase

readme = " ".join((root.parent / "README.md").read_text().split())
for phrase in (
    "installers do not create `.basix/adrs/`, ADR templates, or an initial ADR",
    "agents create the ADR structure only when the first qualifying decision is recorded",
    "binding ADR governance for durable, hard-to-reverse, cross-subsystem decisions",
    "pause for explicit user confirmation before conflicting work or lifecycle changes",
):
    assert phrase in readme, phrase

heartbeat = (root / "skills/basix-subagent-management/references/agent-communication-contract.md").read_text()
heartbeat_flat = " ".join(heartbeat.split())
assert "version=2.0" in heartbeat
assert "cycle_revision" in heartbeat
assert "communicates exclusively with its direct spawning parent" in heartbeat
assert "Escalation is a newly authored parent `issue`" in heartbeat_flat
assert "`cycle_revision + 1`" in heartbeat
assert "subagent_insights" in heartbeat and "at most 24 words" in heartbeat
for phrase in (
    "exactly one logical", "idempotently deduplicated", "Altered same-key",
    "timeout_ms: 1800000", "no unconditional infinite waiting",
    "not failure, cancellation", "at most three active descendants",
    "passing checks and parent acceptance are separate states",
    "Disjoint writers may remain active", "stop the verifier, discard its result",
    "`owned_targets` and `mutation_window`", "mandatory `final_result`",
    "Final result delivered to parent.", "Delivery failed: <short reason>.",
):
    assert phrase in heartbeat_flat, phrase
assert "Plan delivered to parent." not in heartbeat
assert "120000" not in heartbeat and "first status" not in heartbeat
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
printf 'Static Basix verification passed.\n'

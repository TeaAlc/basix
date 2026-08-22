#!/usr/bin/env python3
"""Read-only validator for native agents and Basix message contracts."""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any

TYPES = {"plan", "status", "issue", "permission_request", "report_started", "intermediate_result", "final_result"}
STATUSES = {"planned", "in_progress", "blocked", "completed", "completed_with_errors", "failed"}
EFFORTS = {"low", "medium", "high", "xhigh", "max"}
OVERRIDE = "# basix-agent-authoring: explicit-model-override"
SANDBOX_OVERRIDE = "# basix-agent-authoring: explicit-sandbox-override"
METADATA_START = "# basix-agent-authoring:metadata:start"
METADATA_END = "# basix-agent-authoring:metadata:end"
PRINCIPAL_MARKER = "# basix-agent-authoring: explicit-principal-level"
LEVELS = {"junior", "senior", "principal"}
CANONICAL_LEVELS = {
    "basix_file_explorer": "junior",
    "basix_researcher": "junior",
    "basix_miraculix": "junior",
    "basix_pager": "senior",
    "basix_verifier": "senior",
}
LEGACY_SPAWN_CLAUSES = (
    "Do not spawn subagents.",
    "You may spawn only `basix_file_explorer` and `basix_researcher`.",
    "Do not spawn generic agents, senior agents, or principals.",
    "Do not spawn principals.",
)
BOOTSTRAP_START = "<!-- basix-agent-authoring:bootstrap:start -->"
BOOTSTRAP_END = "<!-- basix-agent-authoring:bootstrap:end -->"
CONTRACT_START = "<!-- basix-agent-authoring:contract:start version=1.4 -->"
CONTRACT_END = "<!-- basix-agent-authoring:contract:end -->"
WORD_RE = re.compile(r"\b[\wÀ-ÖØ-öø-ÿ]+(?:[-'][\wÀ-ÖØ-öø-ÿ]+)*\b", re.UNICODE)


class Invalid(ValueError):
    pass


def words(value: str) -> int:
    return len(WORD_RE.findall(value))


def need(condition: bool, message: str) -> None:
    if not condition:
        raise Invalid(message)


def object_exact(value: Any, required: set[str], optional: set[str] = set()) -> dict[str, Any]:
    need(isinstance(value, dict), "message must be a JSON object")
    missing = required - value.keys()
    extra = value.keys() - required - optional
    need(not missing, f"missing fields: {', '.join(sorted(missing))}")
    need(not extra, f"unexpected fields: {', '.join(sorted(extra))}")
    return value


def validate_error(value: Any, allow_details: bool) -> None:
    obj = object_exact(value, {"code", "message", "severity", "retryable"}, {"details"})
    for key in ("code", "message"):
        need(isinstance(obj[key], str) and bool(obj[key].strip()), f"error.{key} must be non-empty")
    need(obj["severity"] in {"warning", "error", "fatal"}, "invalid error severity")
    need(type(obj["retryable"]) is bool, "error.retryable must be boolean")
    need(allow_details or "details" not in obj, "error details are forbidden for this message type")


def validate_plan_data(value: Any) -> dict[str, Any]:
    need(isinstance(value, dict), "plan/status data must be an object")
    need("plan_revision" in value and "checklist" in value, "plan data requires plan_revision and checklist")
    need(type(value["plan_revision"]) is int and value["plan_revision"] >= 1, "plan_revision must be a positive integer")
    checklist = value["checklist"]
    need(isinstance(checklist, list) and 1 <= len(checklist) <= 8, "checklist must contain one to eight items")
    ids: set[str] = set()
    for index, item in enumerate(checklist, 1):
        obj = object_exact(item, {"id", "text", "checked"})
        need(isinstance(obj["id"], str) and bool(obj["id"].strip()), f"checklist item {index} needs an id")
        need(obj["id"] not in ids, f"duplicate checklist id: {obj['id']}")
        ids.add(obj["id"])
        need(isinstance(obj["text"], str) and 1 <= words(obj["text"]) <= 12, f"checklist item {obj['id']} text exceeds 12 words")
        need(type(obj["checked"]) is bool, f"checklist item {obj['id']} checked must be boolean")
    return value


def validate_message(value: Any) -> dict[str, Any]:
    required = {"contract_version", "message_type", "agent_name", "task_name", "sequence", "cycle_revision", "status", "summary", "data", "errors"}
    msg = object_exact(value, required)
    need(msg["contract_version"] == "1.4", "contract_version must be 1.4")
    kind = msg["message_type"]
    need(kind in TYPES, "invalid message_type")
    for key in ("agent_name", "task_name", "summary"):
        need(isinstance(msg[key], str) and bool(msg[key].strip()), f"{key} must be non-empty")
    need(type(msg["sequence"]) is int and msg["sequence"] >= 1, "sequence must be a positive integer")
    need(type(msg["cycle_revision"]) is int and msg["cycle_revision"] >= 1,
         "cycle_revision must be a positive integer")
    need(msg["status"] in STATUSES, "invalid status")
    need(isinstance(msg["errors"], list), "errors must be an array")
    data = msg["data"]
    if isinstance(data, dict) and "subagent_insights" in data:
        need(kind == "final_result", "subagent_insights is permitted only in final_result data")
        insights = data["subagent_insights"]
        need(isinstance(insights, list) and bool(insights),
             "subagent_insights must be a non-empty array")
        for index, insight in enumerate(insights, 1):
            need(isinstance(insight, str) and bool(insight.strip()),
                 f"subagent insight {index} must be a non-empty string")
            need(words(insight) <= 24, f"subagent insight {index} exceeds 24 words")
    concise = kind in {"issue", "intermediate_result"}
    for error in msg["errors"]:
        validate_error(error, allow_details=not concise)

    limit = 64 if kind in {"plan", "intermediate_result"} else 32 if kind in {"status", "issue", "report_started"} else None
    need(limit is None or words(msg["summary"]) <= limit, f"{kind} summary exceeds {limit} words")
    if kind == "plan":
        need(msg["status"] == "planned", "plan status must be planned")
        validate_plan_data(msg["data"])
        need(not msg["errors"], "plan errors must be empty")
    elif kind == "status":
        need(msg["status"] == "in_progress", "status message status must be in_progress")
        validate_plan_data(msg["data"])
        need(not msg["errors"], "status errors must be empty")
    elif kind == "report_started":
        need(msg["status"] == "in_progress", "report_started status must be in_progress")
        data = object_exact(msg["data"], {"report_type"})
        need(data["report_type"] in {"intermediate_result", "final_result"},
             "report_started report_type must be intermediate_result or final_result")
        need(not msg["errors"], "report_started errors must be empty")
    elif kind in {"issue", "intermediate_result"}:
        need(msg["data"] is None, f"{kind} data must be null")
        need(len(msg["errors"]) <= 3, f"{kind} permits at most three errors")
        if kind == "issue":
            need(bool(msg["errors"]), "issue requires at least one error")
    elif kind == "permission_request":
        need(msg["status"] == "blocked", "permission_request status must be blocked")
        data = object_exact(msg["data"], {"request_id", "action", "reason", "required_permission", "scope", "blocks_current_step"})
        for key in ("request_id", "action", "reason", "required_permission", "scope"):
            need(isinstance(data[key], str) and bool(data[key].strip()), f"permission {key} must be non-empty")
        need(type(data["blocks_current_step"]) is bool, "blocks_current_step must be boolean")
        need(not msg["errors"], "permission_request errors must be empty")
    else:
        need(msg["status"] in {"completed", "completed_with_errors", "failed"}, "invalid final_result status")
        if msg["status"] == "completed":
            need(not msg["errors"], "completed final_result cannot contain errors")
        else:
            need(bool(msg["errors"]), f"{msg['status']} final_result requires errors")
        if msg["status"] == "completed_with_errors":
            need(msg["data"] is not None, "completed_with_errors requires usable data")
    return msg


def validate_stream(messages: list[Any]) -> None:
    need(bool(messages), "stream is empty")
    # State is keyed by agent identity.  Sequence numbers are global for that
    # agent, while each task is one immutable assignment that may have explicit
    # continuation cycles.
    state: dict[str, dict[str, Any]] = {}
    for line, raw in enumerate(messages, 1):
        try:
            msg = validate_message(raw)
        except Invalid as exc:
            raise Invalid(f"line {line}: {exc}") from exc
        agent = msg["agent_name"]
        current = state.setdefault(agent, {
            "sequence": 0,
            "task": None,
            "cycle": None,
            "plan": None,
            "final": False,
            "ids": {},
            "revision": 0,
            "cycles": 0,
            "open_report": None,
        })
        task = msg["task_name"]
        need(msg["sequence"] > current["sequence"],
             f"line {line}: sequence is not strictly increasing for agent {agent}")
        if current["task"] is None:
            current["task"] = task
        else:
            need(task == current["task"],
                 f"line {line}: task_name changed for agent {agent}; use a fresh agent")
        cycle = msg["cycle_revision"]
        if current["cycle"] is None:
            need(msg["message_type"] == "plan", f"line {line}: first task message must be plan")
            need(cycle == 1, f"line {line}: initial cycle_revision must be 1")
            current["cycle"] = cycle
            current["cycles"] = 1
            current["plan"] = None
            current["final"] = False
            current["ids"] = {}
            current["revision"] = 0
            current["open_report"] = None
        elif cycle == current["cycle"]:
            need(not current["final"], f"line {line}: message follows final_result for task {task}; explicit continuation required")
        elif cycle == current["cycle"] + 1:
            need(current["final"], f"line {line}: cycle_revision advanced before final_result")
            need(msg["message_type"] == "plan",
                 f"line {line}: continued cycle must begin with a plan")
            current["cycle"] = cycle
            current["cycles"] += 1
            current["plan"] = None
            current["final"] = False
            current["ids"] = {}
            current["revision"] = 0
            current["open_report"] = None
        else:
            need(False, f"line {line}: cycle_revision must increase by exactly one after explicit continuation")

        current["sequence"] = msg["sequence"]
        kind = msg["message_type"]
        if current["open_report"] is not None:
            if kind in {"status", "issue", "permission_request"}:
                pass
            else:
                need(kind == current["open_report"],
                     f"line {line}: expected announced {current['open_report']}, got {kind}")
                current["open_report"] = None
        elif kind == "report_started":
            current["open_report"] = msg["data"]["report_type"]
        elif kind == "intermediate_result":
            need(False, f"line {line}: intermediate_result requires report_started")
        if kind in {"plan", "status"}:
            data = msg["data"]
            revision = data["plan_revision"]
            old_ids = current["ids"]
            new_ids = {item["id"]: item["text"] for item in data["checklist"]}
            if current["plan"] is None:
                need(msg["message_type"] == "plan",
                     f"line {line}: cycle must begin with a plan")
                need(revision == 1,
                     f"line {line}: first plan in a cycle must use plan_revision 1")
            else:
                need(revision >= current["revision"], f"line {line}: plan_revision decreased")
                for item_id in old_ids.keys() & new_ids.keys():
                    need(old_ids[item_id] == new_ids[item_id],
                         f"line {line}: checklist id {item_id} changed text")
                if msg["message_type"] == "status":
                    need(revision == current["revision"],
                         f"line {line}: structural revision requires a plan message")
                    need(set(new_ids) == set(old_ids),
                         f"line {line}: status changed checklist structure")
                else:
                    need(revision > current["revision"],
                         f"line {line}: revised plan must increment plan_revision")
            if msg["message_type"] == "plan":
                current["plan"] = data
                current["ids"] = new_ids
                current["revision"] = revision
        if kind == "final_result":
            need(current["plan"] is not None,
                 f"line {line}: final_result requires a plan in the current cycle")
            need(not current["final"],
                 f"line {line}: duplicate final_result in cycle {cycle}")
            current["final"] = True
    for agent, current in state.items():
        need(current["open_report"] is None,
             f"agent {agent} stream has an uncompleted report_started announcement")
        need(current["final"], f"agent {agent} stream must end with exactly one final_result per cycle")


def validate_agent(path: Path) -> None:
    try:
        text = path.read_text(encoding="utf-8")
        parsed = tomllib.loads(text)
    except (OSError, UnicodeError, tomllib.TOMLDecodeError) as exc:
        raise Invalid(str(exc)) from exc
    lines = text.splitlines()
    need(lines and lines[0] == METADATA_START,
         f"{path}: metadata block must begin on the first line")
    need(lines.count(METADATA_START) == 1 and lines.count(METADATA_END) == 1,
         f"{path}: metadata markers must occur exactly once")
    metadata_end = lines.index(METADATA_END)
    need(metadata_end in {2, 3}, f"{path}: metadata block is malformed or misplaced")
    metadata_lines = lines[1:metadata_end]
    principal_marker = PRINCIPAL_MARKER in metadata_lines
    need(metadata_lines.count(PRINCIPAL_MARKER) <= 1,
         f"{path}: explicit principal marker must occur at most once")
    payload = "\n".join(
        line[2:] if line.startswith("# ") else ""
        for line in metadata_lines if line != PRINCIPAL_MARKER
    )
    need(bool(payload) and all(line.startswith("# ") for line in metadata_lines),
         f"{path}: metadata content must be commented TOML")
    try:
        metadata_doc = tomllib.loads(payload)
    except tomllib.TOMLDecodeError as exc:
        raise Invalid(f"{path}: invalid metadata TOML: {exc}") from exc
    metadata = object_exact(metadata_doc, {"metadata"})["metadata"]
    metadata = object_exact(metadata, {"author", "level"})
    need(isinstance(metadata["author"], str) and bool(metadata["author"].strip()),
         f"{path}: metadata author must be non-empty")
    need(isinstance(metadata["level"], str) and metadata["level"] in LEVELS,
         f"{path}: metadata level must be junior, senior, or principal")
    need(principal_marker == (metadata["level"] == "principal"),
         f"{path}: principal level requires the explicit-principal-level marker and other levels forbid it")
    for key in ("name", "description", "model", "model_reasoning_effort", "sandbox_mode", "developer_instructions"):
        need(isinstance(parsed.get(key), str) and bool(parsed[key].strip()), f"{path}: missing string field {key}")
    need(parsed["description"].startswith("Basix-Agent: "),
         f"{path}: description must begin with 'Basix-Agent: '")
    need(parsed["name"].startswith("basix_"),
         f"{path}: native agent name must begin with 'basix_'")
    expected_level = CANONICAL_LEVELS.get(parsed["name"])
    if expected_level:
        need(metadata["level"] == expected_level,
             f"{path}: {parsed['name']} must use {expected_level} level")
    model_lines = [i for i, line in enumerate(lines) if re.match(r"^\s*model\s*=", line)]
    need(len(model_lines) == 1, f"{path}: expected exactly one model field")
    index = model_lines[0]
    override = index > 0 and lines[index - 1].strip() == OVERRIDE
    if not override:
        need(parsed["model"] == "gpt-5.6-luna", f"{path}: non-Luna model requires explicit override marker")
        need(parsed["model_reasoning_effort"] in EFFORTS,
             f"{path}: effort must be low, medium, high, xhigh, or max")
    sandbox_lines = [i for i, line in enumerate(lines) if re.match(r"^\s*sandbox_mode\s*=", line)]
    need(len(sandbox_lines) == 1, f"{path}: expected exactly one sandbox_mode field")
    sandbox_index = sandbox_lines[0]
    sandbox_override = sandbox_index > 0 and lines[sandbox_index - 1].strip() == SANDBOX_OVERRIDE
    if parsed["sandbox_mode"] == "workspace-write":
        need(parsed["name"] == "basix_pager",
             f"{path}: workspace-write is reserved for basix_pager")
        need(sandbox_override,
             f"{path}: workspace-write requires an adjacent explicit sandbox override marker")
    else:
        need(parsed["sandbox_mode"] == "read-only", f"{path}: sandbox_mode must be read-only")
        need(not sandbox_override,
             f"{path}: explicit sandbox override marker is reserved for basix_pager workspace-write")
    if parsed["name"] == "basix_file_explorer":
        need(not override and parsed["model"] == "gpt-5.6-luna",
             f"{path}: basix_file_explorer must use gpt-5.6-luna without override")
        need(parsed["model_reasoning_effort"] == "low",
             f"{path}: basix_file_explorer must use low reasoning effort")
    if parsed["name"] == "basix_researcher":
        need(not override and parsed["model"] == "gpt-5.6-luna",
             f"{path}: basix_researcher must use gpt-5.6-luna without override")
        need(parsed["model_reasoning_effort"] == "medium",
             f"{path}: basix_researcher must use medium reasoning effort")
    if parsed["name"] == "basix_miraculix":
        need(override and parsed["model"] == "gpt-5.6-sol",
             f"{path}: basix_miraculix must use explicitly overridden gpt-5.6-sol")
        need(parsed["model_reasoning_effort"] == "low",
             f"{path}: basix_miraculix must use low reasoning effort")
        need(parsed["sandbox_mode"] == "read-only",
             f"{path}: basix_miraculix must remain read-only")
    if parsed["name"] == "basix_pager":
        need(not override and parsed["model"] == "gpt-5.6-luna",
             f"{path}: basix_pager must use classified gpt-5.6-luna without an override")
        need(parsed["model_reasoning_effort"] == "xhigh",
             f"{path}: basix_pager must use xhigh reasoning effort")
    if parsed["name"] == "basix_verifier":
        need(not override and parsed["model"] == "gpt-5.6-luna",
             f"{path}: basix_verifier must use classified gpt-5.6-luna without an override")
        need(parsed["model_reasoning_effort"] == "xhigh",
             f"{path}: basix_verifier must use xhigh reasoning effort")
        need(parsed["sandbox_mode"] == "read-only",
             f"{path}: basix_verifier must remain read-only")
    instructions = parsed["developer_instructions"]
    level_declaration = f"You are a {metadata['level']} Basix agent."
    need(instructions.lstrip().startswith(level_declaration),
         f"{path}: developer_instructions must start with {level_declaration!r}")
    for clause in LEGACY_SPAWN_CLAUSES:
        need(clause not in instructions,
             f"{path}: concrete spawn permissions belong only in the Basix router")
    if parsed["name"] == "basix_researcher":
        researcher_clauses = (
            "expect and use the Scrapling\nMCP server (spelled `scrapling`) when it is needed",
            "inspect the complete available tool inventory, including deferred\ntools exposed through tool discovery",
            "Do not infer that Scrapling is unavailable\nfrom MCP resources or resource templates",
            "Scrapling access is explicitly authorized for read-only research",
            "treat the assignment as blocked and unsuccessful under the communication\ncontract",
            "Tell the spawning parent to install Scrapling with the Basix installer",
            "Basix\nScrapling requires Podman and routes all web requests through the Tor network",
        )
        for clause in researcher_clauses:
            need(clause in instructions, f"{path}: missing required Scrapling researcher policy")
    need(instructions.count(BOOTSTRAP_START) == 1 and instructions.count(BOOTSTRAP_END) == 1,
         f"{path}: bootstrap markers must occur exactly once")
    need(instructions.index(BOOTSTRAP_START) < instructions.index(BOOTSTRAP_END),
         f"{path}: bootstrap markers are reversed")
    need(CONTRACT_START not in instructions and CONTRACT_END not in instructions,
         f"{path}: full communication contract copies are forbidden")
    need("/root" not in parsed["description"] and "/root" not in instructions,
         f"{path}: native roles must address only their spawning parent, never /root")
    need(not re.search(r"\bRoot\b", instructions),
         f"{path}: native role instructions must use spawning-parent terminology, not Root")
    block = instructions[
        instructions.index(BOOTSTRAP_START):instructions.index(BOOTSTRAP_END) + len(BOOTSTRAP_END)
    ]
    reference = path.parents[2] / "skills" / "basix-agent-authoring" / "references" / "native-agent-bootstrap.md"
    if not reference.is_file():
        reference = Path(__file__).resolve().parents[1] / "references" / "native-agent-bootstrap.md"
    try:
        canonical_text = reference.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise Invalid(f"cannot read canonical bootstrap: {exc}") from exc
    need(canonical_text.count(BOOTSTRAP_START) == 1 and canonical_text.count(BOOTSTRAP_END) == 1,
         f"{reference}: canonical bootstrap markers must occur exactly once")
    canonical = canonical_text[
        canonical_text.index(BOOTSTRAP_START):canonical_text.index(BOOTSTRAP_END) + len(BOOTSTRAP_END)
    ]
    need(block == canonical, f"{path}: bootstrap block differs from canonical authoring template")


def load_single() -> Any:
    try:
        return json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        raise Invalid(f"invalid JSON: {exc}") from exc


def load_lines() -> list[Any]:
    result = []
    for number, line in enumerate(sys.stdin, 1):
        if not line.strip():
            continue
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise Invalid(f"line {number}: invalid JSON: {exc}") from exc
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    agent = sub.add_parser("agent")
    agent.add_argument("paths", nargs="+", type=Path)
    for name in ("message", "stream"):
        child = sub.add_parser(name)
        child.add_argument("--stdin", action="store_true", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "agent":
            for path in args.paths:
                validate_agent(path)
        elif args.command == "message":
            validate_message(load_single())
        else:
            validate_stream(load_lines())
    except Invalid as exc:
        print(f"invalid: {exc}", file=sys.stderr)
        return 1
    print("valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

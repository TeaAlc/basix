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

TYPES = {"plan", "status", "issue", "permission_request", "intermediate_result", "final_result"}
STATUSES = {"planned", "in_progress", "blocked", "completed", "completed_with_errors", "failed"}
EFFORTS = {"low", "medium", "high"}
OVERRIDE = "# basix-agent-authoring: explicit-model-override"
START = "<!-- basix-agent-authoring:contract:start version=1.0 -->"
END = "<!-- basix-agent-authoring:contract:end -->"
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
    required = {"contract_version", "message_type", "agent_name", "task_name", "sequence", "status", "summary", "data", "errors"}
    msg = object_exact(value, required)
    need(msg["contract_version"] == "1.0", "contract_version must be 1.0")
    kind = msg["message_type"]
    need(kind in TYPES, "invalid message_type")
    for key in ("agent_name", "task_name", "summary"):
        need(isinstance(msg[key], str) and bool(msg[key].strip()), f"{key} must be non-empty")
    need(type(msg["sequence"]) is int and msg["sequence"] >= 1, "sequence must be a positive integer")
    need(msg["status"] in STATUSES, "invalid status")
    need(isinstance(msg["errors"], list), "errors must be an array")
    concise = kind in {"issue", "intermediate_result"}
    for error in msg["errors"]:
        validate_error(error, allow_details=not concise)

    limit = 64 if kind in {"plan", "intermediate_result"} else 32 if kind in {"status", "issue"} else None
    need(limit is None or words(msg["summary"]) <= limit, f"{kind} summary exceeds {limit} words")
    if kind == "plan":
        need(msg["status"] == "planned", "plan status must be planned")
        validate_plan_data(msg["data"])
        need(not msg["errors"], "plan errors must be empty")
    elif kind == "status":
        need(msg["status"] == "in_progress", "status message status must be in_progress")
        validate_plan_data(msg["data"])
        need(not msg["errors"], "status errors must be empty")
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
    state: dict[str, dict[str, Any]] = {}
    for line, raw in enumerate(messages, 1):
        try:
            msg = validate_message(raw)
        except Invalid as exc:
            raise Invalid(f"line {line}: {exc}") from exc
        task = msg["task_name"]
        current = state.setdefault(task, {"sequence": 0, "plan": None, "finals": 0, "ids": {}, "revision": 0})
        need(msg["sequence"] > current["sequence"], f"line {line}: sequence is not strictly increasing for task {task}")
        need(current["finals"] == 0, f"line {line}: message follows final_result for task {task}")
        current["sequence"] = msg["sequence"]
        if current["plan"] is None:
            need(msg["message_type"] == "plan", f"line {line}: first task message must be plan")
        if msg["message_type"] in {"plan", "status"}:
            data = msg["data"]
            revision = data["plan_revision"]
            need(revision >= current["revision"], f"line {line}: plan_revision decreased")
            old_ids = current["ids"]
            new_ids = {item["id"]: item["text"] for item in data["checklist"]}
            for item_id in old_ids.keys() & new_ids.keys():
                need(old_ids[item_id] == new_ids[item_id], f"line {line}: checklist id {item_id} changed text")
            if msg["message_type"] == "status":
                need(revision == current["revision"], f"line {line}: structural revision requires a plan message")
                need(set(new_ids) == set(old_ids), f"line {line}: status changed checklist structure")
            else:
                need(current["plan"] is None or revision > current["revision"], f"line {line}: revised plan must increment plan_revision")
                current["plan"] = data
                current["ids"] = new_ids
                current["revision"] = revision
        if msg["message_type"] == "final_result":
            current["finals"] += 1
    for task, current in state.items():
        need(current["finals"] == 1, f"task {task} must contain exactly one final_result")


def validate_agent(path: Path) -> None:
    try:
        text = path.read_text(encoding="utf-8")
        parsed = tomllib.loads(text)
    except (OSError, UnicodeError, tomllib.TOMLDecodeError) as exc:
        raise Invalid(str(exc)) from exc
    for key in ("name", "description", "model", "model_reasoning_effort", "sandbox_mode", "developer_instructions"):
        need(isinstance(parsed.get(key), str) and bool(parsed[key].strip()), f"{path}: missing string field {key}")
    need(parsed["description"].startswith("Basix-Agent: "),
         f"{path}: description must begin with 'Basix-Agent: '")
    model_lines = [i for i, line in enumerate(text.splitlines()) if re.match(r"^\s*model\s*=", line)]
    need(len(model_lines) == 1, f"{path}: expected exactly one model field")
    index = model_lines[0]
    lines = text.splitlines()
    override = index > 0 and lines[index - 1].strip() == OVERRIDE
    if not override:
        need(parsed["model"] == "gpt-5.6-luna", f"{path}: non-Luna model requires explicit override marker")
        need(parsed["model_reasoning_effort"] in EFFORTS, f"{path}: effort must be low, medium, or high")
    need(parsed["sandbox_mode"] == "read-only", f"{path}: sandbox_mode must be read-only")
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
    instructions = parsed["developer_instructions"]
    need(instructions.count(START) == 1 and instructions.count(END) == 1, f"{path}: contract markers must occur exactly once")
    need(instructions.index(START) < instructions.index(END), f"{path}: contract markers are reversed")
    block = instructions[instructions.index(START):instructions.index(END) + len(END)]
    reference = path.parents[2] / "skills" / "basix-agent-authoring" / "references" / "communication-contract.md"
    if not reference.is_file():
        reference = Path(__file__).resolve().parents[1] / "references" / "communication-contract.md"
    try:
        canonical_text = reference.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise Invalid(f"cannot read canonical contract: {exc}") from exc
    need(canonical_text.count(START) == 1 and canonical_text.count(END) == 1,
         f"{reference}: canonical contract markers must occur exactly once")
    canonical = canonical_text[canonical_text.index(START):canonical_text.index(END) + len(END)]
    need(block == canonical, f"{path}: contract block differs from canonical authoring template")


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

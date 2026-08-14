#!/usr/bin/env python3
"""Collect cumulative token telemetry from Codex rollout files.

Rollout identity and hierarchy are discovered from session_meta records first.
Legacy filenames and sub_agent_activity events are used only when metadata is
absent. Output is sanitized and never contains rollout paths or event contents.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import BinaryIO, Iterable


SCHEMA_VERSION = 2
TOKEN_FIELDS = (
    "input_tokens", "cached_input_tokens", "cache_write_input_tokens",
    "output_tokens", "reasoning_output_tokens", "total_tokens",
)
PARTIAL_CODES = {
    "CONTEXT_WINDOW_MISSING", "ROLLOUT_NOT_FOUND", "TOKEN_EVENT_MISSING",
    "TOKEN_METRIC_MISSING", "TRAILING_JSON_FRAGMENT",
}
ERROR_CODES = {
    "AGENT_PATH_CONFLICT", "AGENT_ROLE_CONFLICT", "DIRECTORY_UNREADABLE",
    "INTERNAL_ERROR", "INVALID_EVENT_TIMESTAMP", "INVALID_SESSION_META",
    "INVALID_SUB_AGENT_ACTIVITY", "INVALID_TOKEN_VALUE", "MALFORMED_JSONL",
    "PARENT_THREAD_CONFLICT", "ROLLOUT_AMBIGUOUS", "ROLLOUT_ID_CONFLICT",
    "ROLLOUT_NOT_REGULAR", "ROLLOUT_SYMLINK", "ROLLOUT_UNREADABLE",
}
UUID_PATTERN = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
ROLLOUT_NAME = re.compile(
    rf"^rollout-\d{{4}}-\d{{2}}-\d{{2}}T\d{{2}}-\d{{2}}-\d{{2}}-"
    rf"(?P<thread_id>{UUID_PATTERN})\.jsonl$", re.IGNORECASE,
)


class UsageError(Exception):
    """Signal an invalid command-line invocation without echoing its values."""


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise UsageError(message)


@dataclass(frozen=True)
class SessionMeta:
    thread_id: str
    timestamp: datetime
    parent_thread_id: str | None
    agent_path: str | None
    agent_role: str | None


@dataclass(frozen=True)
class IndexedEntry:
    path: Path
    kind: str
    filename_id: str
    metadata: SessionMeta | None = None
    warnings: frozenset[str] = frozenset()


@dataclass
class FileIndex:
    entries: dict[str, list[IndexedEntry]] = field(default_factory=dict)
    metadata_children: dict[str, list[SessionMeta]] = field(default_factory=dict)
    metadata_thread_ids: set[str] = field(default_factory=set)
    warnings: set[str] = field(default_factory=set)


@dataclass
class ParsedThread:
    tokens: dict[str, int | None] = field(
        default_factory=lambda: {name: None for name in TOKEN_FIELDS}
    )
    model_context_window: int | None = None
    children: list[tuple[str, str]] = field(default_factory=list)
    warnings: set[str] = field(default_factory=set)


def utc_text(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def parse_timestamp(value: object) -> datetime:
    if not isinstance(value, str):
        raise ValueError
    candidate = value[:-1] + "+00:00" if value.endswith(("Z", "z")) else value
    parsed = datetime.fromisoformat(candidate)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError
    return parsed.astimezone(timezone.utc)


def canonical_uuid(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError
    parsed = uuid.UUID(value)
    canonical = str(parsed)
    if value.lower() != canonical:
        raise ValueError
    return canonical


def build_parser() -> SafeArgumentParser:
    parser = SafeArgumentParser(description="Collect sanitized token telemetry for one Codex thread tree.")
    parser.add_argument("--thread-id", default=os.environ.get("CODEX_THREAD_ID"))
    default_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    parser.add_argument("--sessions-dir", type=Path, default=default_home / "sessions")
    parser.add_argument("--cutoff")
    parser.add_argument("--format", choices=("json", "text"), default="json")
    return parser


def open_regular_file(path: Path) -> BinaryIO:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise OSError("not a regular file")
        return os.fdopen(descriptor, "rb")
    except Exception:
        os.close(descriptor)
        raise


def parse_session_meta(event: object) -> SessionMeta:
    if not isinstance(event, dict) or event.get("type") != "session_meta":
        raise ValueError
    payload = event.get("payload")
    if not isinstance(payload, dict):
        raise ValueError
    thread_id = canonical_uuid(payload.get("id"))
    timestamp = parse_timestamp(event.get("timestamp"))
    source = payload.get("source")
    spawn = None
    if isinstance(source, dict):
        subagent = source.get("subagent")
        if isinstance(subagent, dict):
            spawn = subagent.get("thread_spawn")
    if spawn is None:
        return SessionMeta(thread_id, timestamp, None, None, None)
    if not isinstance(spawn, dict):
        raise ValueError
    parent_id = canonical_uuid(spawn.get("parent_thread_id"))
    agent_path = spawn.get("agent_path")
    agent_role = spawn.get("agent_role")
    if not isinstance(agent_path, str) or not agent_path.strip():
        raise ValueError
    if not isinstance(agent_role, str) or not agent_role.strip():
        raise ValueError
    return SessionMeta(thread_id, timestamp, parent_id, agent_path, agent_role)


def inspect_metadata(path: Path, filename_id: str, cutoff: datetime) -> tuple[SessionMeta | None, set[str]]:
    warnings: set[str] = set()
    metas: list[SessionMeta] = []
    first_meta_seen = False
    try:
        handle = open_regular_file(path)
    except OSError:
        return None, {"ROLLOUT_UNREADABLE"}
    try:
        with handle:
            for raw in handle:
                try:
                    event = json.loads(raw)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if not isinstance(event, dict) or event.get("type") != "session_meta":
                    continue
                is_first = not first_meta_seen
                first_meta_seen = True
                try:
                    meta = parse_session_meta(event)
                except (TypeError, ValueError, AttributeError):
                    warnings.add("INVALID_SESSION_META")
                    continue
                if is_first:
                    metas.append(meta)
                elif metas and meta.timestamp <= cutoff and metas[0].timestamp <= cutoff and meta != metas[0]:
                    if meta.thread_id != metas[0].thread_id:
                        warnings.add("ROLLOUT_ID_CONFLICT")
                    if meta.parent_thread_id != metas[0].parent_thread_id:
                        warnings.add("PARENT_THREAD_CONFLICT")
                    if meta.agent_path != metas[0].agent_path:
                        warnings.add("AGENT_PATH_CONFLICT")
                    if meta.agent_role != metas[0].agent_role:
                        warnings.add("AGENT_ROLE_CONFLICT")
    except OSError:
        warnings.add("ROLLOUT_UNREADABLE")
    metadata = metas[0] if metas else None
    if metadata is not None and metadata.thread_id != filename_id:
        warnings.add("ROLLOUT_ID_CONFLICT")
    return metadata, warnings


def index_rollouts(sessions_dir: Path, cutoff: datetime) -> FileIndex:
    index = FileIndex()
    discovered: list[IndexedEntry] = []

    def visit(directory: Path) -> None:
        try:
            with os.scandir(directory) as iterator:
                entries = list(iterator)
        except OSError:
            index.warnings.add("DIRECTORY_UNREADABLE")
            return
        for entry in entries:
            path = Path(entry.path)
            try:
                match = ROLLOUT_NAME.fullmatch(entry.name)
                if entry.is_symlink():
                    if match:
                        filename_id = match.group("thread_id").lower()
                        discovered.append(IndexedEntry(path, "symlink", filename_id))
                    continue
                if entry.is_dir(follow_symlinks=False):
                    visit(path)
                    continue
                if not match:
                    continue
                filename_id = match.group("thread_id").lower()
                if not entry.is_file(follow_symlinks=False):
                    discovered.append(IndexedEntry(path, "other", filename_id))
                    continue
                metadata, warnings = inspect_metadata(path, filename_id, cutoff)
                discovered.append(IndexedEntry(path, "regular", filename_id, metadata, frozenset(warnings)))
            except OSError:
                index.warnings.add("DIRECTORY_UNREADABLE")

    visit(sessions_dir)
    by_meta_id: dict[str, list[SessionMeta]] = {}
    for entry in discovered:
        identity = entry.metadata.thread_id if entry.metadata is not None else entry.filename_id
        index.entries.setdefault(identity, []).append(entry)
        if entry.metadata is None:
            continue
        meta = entry.metadata
        index.metadata_thread_ids.add(meta.thread_id)
        if meta.timestamp <= cutoff:
            by_meta_id.setdefault(meta.thread_id, []).append(meta)
        if meta.parent_thread_id is not None and meta.timestamp <= cutoff:
            index.metadata_children.setdefault(meta.parent_thread_id, []).append(meta)

    for metas in by_meta_id.values():
        first = metas[0]
        for meta in metas[1:]:
            if meta.parent_thread_id != first.parent_thread_id:
                index.warnings.add("PARENT_THREAD_CONFLICT")
            if meta.agent_path != first.agent_path:
                index.warnings.add("AGENT_PATH_CONFLICT")
            if meta.agent_role != first.agent_role:
                index.warnings.add("AGENT_ROLE_CONFLICT")
    for parent, metas in index.metadata_children.items():
        unique = {(m.thread_id, m.parent_thread_id, m.agent_path, m.agent_role): m for m in metas}
        index.metadata_children[parent] = sorted(unique.values(), key=lambda m: m.thread_id)
    return index


def valid_metric(value: object) -> bool:
    return value is None or (isinstance(value, int) and not isinstance(value, bool) and value >= 0)


def parse_token_payload(payload: dict[str, object], parsed: ParsedThread) -> tuple[dict[str, int | None], int | None] | None:
    info = payload.get("info")
    if not isinstance(info, dict) or not isinstance(info.get("total_token_usage"), dict):
        parsed.warnings.add("INVALID_TOKEN_VALUE")
        return None
    totals = info["total_token_usage"]
    assert isinstance(totals, dict)
    values = {name: totals.get(name) if valid_metric(totals.get(name)) else None for name in TOKEN_FIELDS}
    context_window = info.get("model_context_window")
    if any(not valid_metric(totals.get(name)) for name in TOKEN_FIELDS) or not valid_metric(context_window):
        parsed.warnings.add("INVALID_TOKEN_VALUE")
        return None
    return values, context_window


def parse_activity_payload(payload: dict[str, object], parsed: ParsedThread) -> tuple[str, str] | None:
    if payload.get("kind") != "started":
        return None
    try:
        child_id = canonical_uuid(payload.get("agent_thread_id"))
    except (ValueError, AttributeError):
        parsed.warnings.add("INVALID_SUB_AGENT_ACTIVITY")
        return None
    agent_path = payload.get("agent_path")
    if not isinstance(agent_path, str) or not agent_path.strip():
        parsed.warnings.add("INVALID_SUB_AGENT_ACTIVITY")
        return None
    return child_id, agent_path


def parse_rollout(path: Path, cutoff: datetime) -> ParsedThread:
    parsed = ParsedThread()
    latest_tokens: tuple[datetime, int, dict[str, int | None], int | None] | None = None
    latest_children: dict[str, tuple[datetime, int, str]] = {}
    position = 0
    try:
        handle = open_regular_file(path)
    except OSError:
        parsed.warnings.add("ROLLOUT_UNREADABLE")
        return parsed
    try:
        with handle:
            while True:
                raw = handle.readline()
                if not raw:
                    break
                position += 1
                complete = raw.endswith(b"\n")
                try:
                    event = json.loads(raw)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    parsed.warnings.add("MALFORMED_JSONL" if complete else "TRAILING_JSON_FRAGMENT")
                    continue
                if not isinstance(event, dict) or event.get("type") != "event_msg":
                    continue
                payload = event.get("payload")
                if not isinstance(payload, dict) or payload.get("type") not in {"token_count", "sub_agent_activity"}:
                    continue
                try:
                    timestamp = parse_timestamp(event.get("timestamp"))
                except (TypeError, ValueError):
                    parsed.warnings.add("INVALID_EVENT_TIMESTAMP")
                    continue
                if timestamp > cutoff:
                    continue
                if payload.get("type") == "token_count":
                    token_state = parse_token_payload(payload, parsed)
                    if token_state is not None and (latest_tokens is None or (timestamp, position) >= latest_tokens[:2]):
                        latest_tokens = (timestamp, position, token_state[0], token_state[1])
                    continue
                child = parse_activity_payload(payload, parsed)
                if child is None:
                    continue
                child_id, agent_path = child
                previous = latest_children.get(child_id)
                if previous is not None and previous[2] != agent_path:
                    parsed.warnings.add("AGENT_PATH_CONFLICT")
                if previous is None or (timestamp, position) >= previous[:2]:
                    latest_children[child_id] = (timestamp, position, agent_path)
    except OSError:
        parsed.warnings.add("ROLLOUT_UNREADABLE")
    if latest_tokens is None:
        parsed.warnings.add("TOKEN_EVENT_MISSING")
    else:
        parsed.tokens, parsed.model_context_window = latest_tokens[2], latest_tokens[3]
        if any(value is None for value in parsed.tokens.values()):
            parsed.warnings.add("TOKEN_METRIC_MISSING")
        if parsed.model_context_window is None:
            parsed.warnings.add("CONTEXT_WINDOW_MISSING")
    parsed.children = [(thread_id, data[2]) for thread_id, data in sorted(latest_children.items())]
    return parsed


def status_for(warnings: Iterable[str]) -> str:
    warning_set = set(warnings)
    if warning_set & ERROR_CODES:
        return "error"
    if warning_set & PARTIAL_CODES:
        return "partial"
    return "ok"


def empty_thread(thread_id: str, agent_path: str, role: str, agent_role: str | None, warnings: set[str]) -> dict[str, object]:
    record: dict[str, object] = {
        "thread_id": thread_id, "agent_path": agent_path, "role": role,
        "agent_role": agent_role, "status": status_for(warnings),
    }
    record.update({name: None for name in TOKEN_FIELDS})
    record["model_context_window"] = None
    record["warnings"] = sorted(warnings)
    return record


def collect(root_thread_id: str, sessions_dir: Path, cutoff: datetime, snapshot: datetime) -> dict[str, object]:
    index = index_rollouts(sessions_dir, cutoff)
    global_warnings = set(index.warnings)
    threads: list[dict[str, object]] = []
    assignments: dict[str, str] = {root_thread_id: "/root"}
    queue: list[tuple[str, str, str, str | None]] = [(root_thread_id, "/root", "root", None)]
    visited: set[str] = set()
    while queue:
        thread_id, agent_path, role, agent_role = queue.pop(0)
        if thread_id in visited:
            continue
        visited.add(thread_id)
        entries = index.entries.get(thread_id, [])
        warnings: set[str] = set()
        regular = [entry for entry in entries if entry.kind == "regular"]
        if any(entry.kind == "symlink" for entry in entries): warnings.add("ROLLOUT_SYMLINK")
        if any(entry.kind == "other" for entry in entries): warnings.add("ROLLOUT_NOT_REGULAR")
        if len(entries) > 1: warnings.add("ROLLOUT_AMBIGUOUS")
        if not entries: warnings.add("ROLLOUT_NOT_FOUND")
        parsed = None
        if len(entries) == 1 and len(regular) == 1:
            warnings.update(regular[0].warnings)
            parsed = parse_rollout(regular[0].path, cutoff)
            warnings.update(parsed.warnings)
        if parsed is None:
            record = empty_thread(thread_id, agent_path, role, agent_role, warnings)
        else:
            record = {
                "thread_id": thread_id, "agent_path": agent_path, "role": role,
                "agent_role": agent_role, "status": status_for(warnings), **parsed.tokens,
                "model_context_window": parsed.model_context_window, "warnings": sorted(warnings),
            }
            metadata_children = index.metadata_children.get(thread_id, [])
            metadata_ids = {meta.thread_id for meta in metadata_children}
            children = [(m.thread_id, m.agent_path or "", m.agent_role) for m in metadata_children]
            for child_id, child_path in parsed.children:
                if child_id in index.metadata_thread_ids or child_id in metadata_ids:
                    continue
                children.append((child_id, child_path, None))
            for child_id, child_path, child_role in children:
                previous_path = assignments.get(child_id)
                if previous_path is not None and previous_path != child_path:
                    warnings.add("AGENT_PATH_CONFLICT")
                    record["status"], record["warnings"] = "error", sorted(warnings)
                    continue
                if child_id not in visited and previous_path is None:
                    assignments[child_id] = child_path
                    queue.append((child_id, child_path, "subagent", child_role))
        global_warnings.update(warnings)
        threads.append(record)
    aggregate: dict[str, int | float | None] = {}
    for name in TOKEN_FIELDS:
        values = [thread[name] for thread in threads]
        aggregate[name] = sum(values) if all(isinstance(v, int) and not isinstance(v, bool) for v in values) else None
    aggregate["cache_hit_rate_percent"] = None
    if isinstance(aggregate["input_tokens"], int) and isinstance(aggregate["cached_input_tokens"], int) and aggregate["input_tokens"] > 0:
        aggregate["cache_hit_rate_percent"] = round(aggregate["cached_input_tokens"] / aggregate["input_tokens"] * 100, 1)
    return {
        "schema_version": SCHEMA_VERSION, "status": status_for(global_warnings),
        "snapshot_at": utc_text(snapshot), "cutoff": utc_text(cutoff),
        "root_thread_id": root_thread_id, "threads": threads,
        "aggregate": aggregate, "warnings": sorted(global_warnings),
    }


def render_text(document: dict[str, object]) -> str:
    lines = [
        f"schema_version: {document['schema_version']}", f"status: {document['status']}",
        f"snapshot_at: {document['snapshot_at']}", f"cutoff: {document['cutoff']}",
        f"root_thread_id: {document['root_thread_id']}", "threads:",
    ]
    for thread in document["threads"]:
        assert isinstance(thread, dict)
        fields = ("thread_id", "agent_path", "role", "agent_role", "status", *TOKEN_FIELDS, "model_context_window")
        values = " ".join(f"{name}={json.dumps(thread[name], ensure_ascii=True, separators=(',', ':'))}" for name in fields)
        lines.append(f"- {values}")
    lines.append("aggregate:")
    aggregate = document["aggregate"]
    assert isinstance(aggregate, dict)
    for name in (*TOKEN_FIELDS, "cache_hit_rate_percent"):
        lines.append(f"  {name}: {json.dumps(aggregate[name], separators=(',', ':'))}")
    warnings = document["warnings"]
    assert isinstance(warnings, list)
    lines.append(f"warnings: {','.join(warnings) if warnings else 'none'}")
    return "\n".join(lines) + "\n"


def safe_error_document(root_thread_id: str, cutoff: datetime, snapshot: datetime) -> dict[str, object]:
    warnings = {"INTERNAL_ERROR"}
    aggregate = {name: None for name in TOKEN_FIELDS}
    aggregate["cache_hit_rate_percent"] = None
    return {
        "schema_version": SCHEMA_VERSION, "status": "error", "snapshot_at": utc_text(snapshot),
        "cutoff": utc_text(cutoff), "root_thread_id": root_thread_id,
        "threads": [empty_thread(root_thread_id, "/root", "root", None, warnings)],
        "aggregate": aggregate, "warnings": sorted(warnings),
    }


def main(argv: list[str] | None = None) -> int:
    snapshot = datetime.now(timezone.utc)
    try:
        arguments = build_parser().parse_args(argv)
        root_thread_id = canonical_uuid(arguments.thread_id)
        cutoff = parse_timestamp(arguments.cutoff) if arguments.cutoff else snapshot
    except (UsageError, ValueError, TypeError, AttributeError):
        print("error: invalid invocation", file=sys.stderr)
        return 64
    try:
        document = collect(root_thread_id, arguments.sessions_dir, cutoff, snapshot)
    except Exception:
        document = safe_error_document(root_thread_id, cutoff, snapshot)
    if arguments.format == "text":
        sys.stdout.write(render_text(document))
    else:
        json.dump(document, sys.stdout, sort_keys=True, separators=(",", ":"))
        sys.stdout.write("\n")
    return {"ok": 0, "partial": 1, "error": 2}[str(document["status"])]


if __name__ == "__main__":
    raise SystemExit(main())

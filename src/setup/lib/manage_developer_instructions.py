#!/usr/bin/env python3
"""Atomically manage Basix developer instructions and native-agent config."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import tempfile
import tomllib

START = "<!-- basix:developer-instructions:start -->"
END = "<!-- basix:developer-instructions:end -->"
AGENT_START = "# basix:agent-config:start"
AGENT_END = "# basix:agent-config:end"
KEY_RE = re.compile(r"^[ \t]*(?:developer_instructions|['\"]developer_instructions['\"])[ \t]*=")
TABLE_RE = re.compile(r"^[ \t]*\[")
AGENT_TABLE_RE = re.compile(
    r"^[ \t]*\[agents\.([A-Za-z0-9_-]+)\][ \t]*(?:#.*)?(?:\r?\n)?$"
)


class ConfigError(ValueError):
    pass


def raw_marker_span(text: str, start: str, end: str) -> tuple[int, int] | None:
    starts = [match.start() for match in re.finditer(re.escape(start), text)]
    ends = [match.end() for match in re.finditer(re.escape(end), text)]
    if not starts and not ends:
        return None
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        raise ConfigError(f"configuration contains damaged or duplicate {start} markers")
    block_end = ends[0]
    if block_end < len(text) and text[block_end] == "\n":
        block_end += 1
    return starts[0], block_end


def load_agents(source: Path, installed: Path) -> list[tuple[str, Path]]:
    agents: list[tuple[str, Path]] = []
    if not source.is_dir():
        raise ConfigError(f"agent source directory not found: {source}")
    for path in sorted(source.glob("*.toml")):
        try:
            value = tomllib.loads(path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as exc:
            raise ConfigError(f"invalid agent TOML {path}: {exc}") from exc
        name = value.get("name")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", name):
            raise ConfigError(f"agent TOML has no valid name: {path}")
        agents.append((name, (installed / path.name).absolute()))
    if not agents:
        raise ConfigError(f"no agent TOMLs found in: {source}")
    names = [name for name, _ in agents]
    if len(names) != len(set(names)):
        raise ConfigError("agent TOMLs contain duplicate names")
    return agents


def render_agent_block(agents: list[tuple[str, Path]]) -> str:
    lines = [AGENT_START]
    for name, path in agents:
        lines.extend((f"[agents.{name}]", f"config_file = {json.dumps(str(path))}", ""))
    lines.append(AGENT_END)
    return "\n".join(lines) + "\n"


def strip_managed_agent_content(
    text: str, names: set[str]
) -> tuple[str, bool]:
    """Remove marker lines and known Basix agent tables, preserving all other bytes."""
    span = raw_marker_span(text, AGENT_START, AGENT_END)
    if span is None:
        return text, False

    block = text[span[0] : span[1]]
    kept: list[str] = []
    pending_comments: list[str] = []
    in_managed_table = False
    for line in block.splitlines(keepends=True):
        if AGENT_START in line or AGENT_END in line:
            pending_comments.clear()
            in_managed_table = False
            continue
        table = AGENT_TABLE_RE.match(line)
        if TABLE_RE.match(line):
            next_is_managed = bool(table and table.group(1) in names)
            if in_managed_table and not next_is_managed:
                kept.extend(pending_comments)
            pending_comments.clear()
            in_managed_table = next_is_managed
            if in_managed_table:
                continue
        if in_managed_table:
            if not line.strip() or line.lstrip().startswith("#"):
                pending_comments.append(line)
            else:
                pending_comments.clear()
        else:
            kept.append(line)

    return text[: span[0]] + "".join(kept) + text[span[1] :], True


def agent_update_text(
    text: str, agents: list[tuple[str, Path]], action: str
) -> tuple[str, str]:
    span = raw_marker_span(text, AGENT_START, AGENT_END)
    expected = render_agent_block(agents)
    if action == "agent-add" and span is not None and text[span[0] : span[1]] == expected:
        return text, "unchanged"

    names = {name for name, _ in agents}
    outside, had_marker = strip_managed_agent_content(text, names)
    try:
        parsed = tomllib.loads(outside) if outside.strip() else {}
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"invalid TOML outside managed agent block: {exc}") from exc
    foreign_agents = parsed.get("agents", {})
    if foreign_agents is not None and not isinstance(foreign_agents, dict):
        raise ConfigError("top-level agents must be a table")
    conflicts = sorted(name for name, _ in agents if name in (foreign_agents or {}))
    if conflicts:
        raise ConfigError(
            "foreign agent definition conflicts with Basix: " + ", ".join(conflicts)
        )

    if action == "agent-check":
        return text, "unchanged"
    if action == "agent-add":
        separator = "" if not outside or outside.endswith("\n") else "\n"
        result = outside + separator + expected
        tomllib.loads(result)
        return result, "changed"
    if not had_marker:
        return text, "unchanged"
    result = outside
    tomllib.loads(result) if result.strip() else None
    return result, "changed"


def marker_span(value: str) -> tuple[int, int] | None:
    starts = [m.start() for m in re.finditer(re.escape(START), value)]
    ends = [m.end() for m in re.finditer(re.escape(END), value)]
    if not starts and not ends:
        return None
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        raise ConfigError("developer_instructions contains damaged or duplicate Basix markers")
    return starts[0], ends[0]


def locate_assignment(text: str) -> tuple[int, int] | None:
    lines = text.splitlines(keepends=True)
    offset = 0
    for index, line in enumerate(lines):
        stripped = line.lstrip()
        if TABLE_RE.match(line) and not stripped.startswith("[["):
            break
        if TABLE_RE.match(line):
            break
        if KEY_RE.match(line):
            start = offset
            candidate = ""
            for part in lines[index:]:
                candidate += part
                try:
                    parsed = tomllib.loads(candidate)
                except tomllib.TOMLDecodeError:
                    continue
                if set(parsed) == {"developer_instructions"}:
                    return start, start + len(candidate)
            raise ConfigError("could not determine developer_instructions assignment")
        offset += len(line)
    return None


def clean_joined_value(value: str) -> str:
    return value.strip("\n")


def render_assignment(value: str) -> str:
    return f"developer_instructions = {json.dumps(value, ensure_ascii=False)}\n"


def assignment_comment_suffix(assignment: str) -> str:
    """Return an inline TOML comment and its exact surrounding whitespace."""
    quote: str | None = None
    triple = False
    index = 0
    while index < len(assignment):
        if quote is not None:
            delimiter = quote * (3 if triple else 1)
            if assignment.startswith(delimiter, index):
                index += len(delimiter)
                quote = None
                triple = False
                continue
            if quote == '"' and assignment[index] == "\\":
                index += 2
                continue
            index += 1
            continue
        if assignment.startswith("'''", index) or assignment.startswith('"""', index):
            quote = assignment[index]
            triple = True
            index += 3
            continue
        if assignment[index] in "'\"":
            quote = assignment[index]
            index += 1
            continue
        if assignment[index] == "#":
            start = index
            line_start = assignment.rfind("\n", 0, index) + 1
            while start > line_start and assignment[start - 1] in " \t":
                start -= 1
            return assignment[start:]
        index += 1
    return ""


def update_text(text: str, block: str, action: str) -> tuple[str, bool]:
    try:
        parsed = tomllib.loads(text) if text.strip() else {}
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"invalid TOML: {exc}") from exc

    current = parsed.get("developer_instructions")
    if current is not None and not isinstance(current, str):
        raise ConfigError("top-level developer_instructions must be a string")
    assignment = locate_assignment(text)
    if (current is None) != (assignment is None):
        raise ConfigError("could not safely locate top-level developer_instructions")

    value = current or ""
    span = marker_span(value)
    if action == "add":
        if span:
            value = value[: span[0]] + block + value[span[1] :]
        else:
            separator = "" if not value else ("" if value.endswith("\n\n") else "\n" if value.endswith("\n") else "\n\n")
            value = value + separator + block
    else:
        if not span:
            return text, False
        start, end = span
        if start >= 2 and value[start - 2 : start] == "\n\n":
            start -= 2
        elif start >= 1 and value[start - 1 : start] == "\n":
            start -= 1
        value = value[:start] + value[end:]

    if assignment:
        before, after = text[: assignment[0]], text[assignment[1] :]
        suffix = assignment_comment_suffix(text[assignment[0] : assignment[1]])
        if value:
            rendered = render_assignment(value)
            replacement = rendered.rstrip("\n") + suffix if suffix else rendered
        else:
            replacement = suffix
        result = before + replacement + after
    elif value:
        separator = "" if not text or text.endswith("\n") else "\n"
        result = text + separator + render_assignment(value)
    else:
        result = text

    tomllib.loads(result) if result.strip() else None
    return result, result != text


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "action", choices=("add", "remove", "agent-check", "agent-add", "agent-remove")
    )
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--instructions", type=Path)
    parser.add_argument("--agents-source", type=Path)
    parser.add_argument("--agents-dir", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--remove-empty-file", action="store_true")
    parser.add_argument("--status-json", action="store_true")
    args = parser.parse_args()

    if args.action == "add" and not args.instructions:
        parser.error("add requires --instructions")
    if args.action.startswith("agent-") and (not args.agents_source or not args.agents_dir):
        parser.error(f"{args.action} requires --agents-source and --agents-dir")
    if args.config.exists():
        with args.config.open("r", encoding="utf-8", newline="") as handle:
            original = handle.read()
    else:
        original = ""
    if args.action.startswith("agent-"):
        agents = load_agents(args.agents_source, args.agents_dir)
        updated, status = agent_update_text(original, agents, args.action)
        changed = status == "changed"
        if changed and not args.dry_run:
            if args.action == "agent-remove" and args.remove_empty_file and not updated.strip():
                args.config.unlink(missing_ok=True)
            else:
                atomic_write(args.config, updated)
        result = {"status": status, "action": args.action, "dry_run": args.dry_run}
        if args.status_json:
            print(json.dumps(result))
        elif status == "preserved":
            print(f"Preserved locally changed Basix agent configuration: {args.config}")
        elif changed:
            verb = "Would update" if args.dry_run else "Updated"
            print(f"{verb} Basix agent configuration: {args.config}")
        else:
            print(f"Basix agent configuration already current: {args.config}")
        return 0
    block = args.instructions.read_text(encoding="utf-8").strip() if args.instructions else ""
    if args.action == "add":
        if block.count(START) != 1 or block.count(END) != 1 or block.index(START) >= block.index(END):
            raise ConfigError("instruction source must contain exactly one ordered marker pair")
    updated, changed = update_text(original, block, args.action)
    current = tomllib.loads(original).get("developer_instructions", "") if original.strip() else ""
    existing_span = marker_span(current)
    if not changed:
        if args.status_json:
            print(json.dumps({"status": "unchanged", "action": args.action}))
            return 0
        if args.action == "add":
            print(f"Basix developer instructions already current: {args.config}")
        else:
            print(f"Basix developer instructions not present: {args.config}")
        return 0
    if args.dry_run:
        if args.status_json:
            print(json.dumps({"status": "changed", "action": args.action, "dry_run": True}))
            return 0
        if args.action == "add":
            verb = "update" if existing_span else "add"
            print(f"Would {verb} Basix developer instructions: {args.config}")
        else:
            print(f"Would remove Basix developer instructions: {args.config}")
            if args.remove_empty_file and not updated.strip():
                print(f"Would remove empty configuration file: {args.config}")
        return 0
    if args.action == "remove" and args.remove_empty_file and not updated.strip():
        args.config.unlink(missing_ok=True)
        if not args.status_json:
            print(f"Removed Basix developer instructions: {args.config}")
            print(f"Removed empty configuration file: {args.config}")
    else:
        atomic_write(args.config, updated)
        if args.action == "add" and not args.status_json:
            verb = "Updated" if existing_span else "Added"
            print(f"{verb} Basix developer instructions: {args.config}")
        elif not args.status_json:
            print(f"Removed Basix developer instructions: {args.config}")
    if args.status_json:
        # The human-readable branch above is retained for direct use; installers
        # request JSON and consume only the final record.
        print(json.dumps({"status": "changed", "action": args.action, "dry_run": False}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ConfigError, OSError) as exc:
        print(f"error: {exc}", file=__import__("sys").stderr)
        raise SystemExit(1)

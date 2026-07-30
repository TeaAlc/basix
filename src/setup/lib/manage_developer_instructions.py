#!/usr/bin/env python3
"""Atomically add, update, or remove Basix developer instructions."""

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
KEY_RE = re.compile(r"^[ \t]*(?:developer_instructions|['\"]developer_instructions['\"])[ \t]*=")
TABLE_RE = re.compile(r"^[ \t]*\[")


class ConfigError(ValueError):
    pass


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
            value = "\n\n".join(part for part in (clean_joined_value(value), block) if part)
    else:
        if not span:
            return text, False
        value = clean_joined_value(value[: span[0]] + value[span[1] :])

    if assignment:
        before, after = text[: assignment[0]], text[assignment[1] :]
        replacement = render_assignment(value) if value else ""
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
    parser.add_argument("action", choices=("add", "remove"))
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--instructions", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--remove-empty-file", action="store_true")
    args = parser.parse_args()

    if args.action == "add" and not args.instructions:
        parser.error("add requires --instructions")
    original = args.config.read_text(encoding="utf-8") if args.config.exists() else ""
    block = args.instructions.read_text(encoding="utf-8").strip() if args.instructions else ""
    if args.action == "add":
        if block.count(START) != 1 or block.count(END) != 1 or block.index(START) >= block.index(END):
            raise ConfigError("instruction source must contain exactly one ordered marker pair")
    updated, changed = update_text(original, block, args.action)
    if not changed:
        return 0
    if args.dry_run:
        print(f"Would update {args.config}")
        return 0
    if args.action == "remove" and args.remove_empty_file and not updated.strip():
        args.config.unlink(missing_ok=True)
    else:
        atomic_write(args.config, updated)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ConfigError, OSError) as exc:
        print(f"error: {exc}", file=__import__("sys").stderr)
        raise SystemExit(1)

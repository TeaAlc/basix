#!/usr/bin/env python3
"""Find Scrapling registrations in `codex mcp list --json` without leaking secrets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

MARKER = re.compile(r"scrapling|basix[/_.-]?scrapling|scrapling-tor|policy_mcp", re.I)
SECRET = re.compile(r"token|secret|password|passwd|authorization|cookie|api[_-]?key|proxy_auth", re.I)


def registrations(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in ("servers", "mcp_servers", "items"):
            if isinstance(value.get(key), list):
                return value[key]
    raise ValueError("expected a JSON array (or an object containing a server array)")


def transport(entry):
    nested = entry.get("transport")
    return nested if isinstance(nested, dict) else entry


def reasons(entry):
    found = []
    fields = {
        "name": entry.get("name"),
        "command": transport(entry).get("command"),
        "args": transport(entry).get("args"),
        "cwd": transport(entry).get("cwd"),
        "env": transport(entry).get("env"),
        "url": transport(entry).get("url"),
    }
    for field, value in fields.items():
        if MARKER.search(json.dumps(value, sort_keys=True, ensure_ascii=True)):
            found.append(field)
    return found


def safe(entry, why):
    spec = transport(entry)
    status = "enabled" if entry.get("enabled", not entry.get("disabled", False)) else "disabled"
    result = {"name": str(entry.get("name", "<unnamed>")), "status": status, "reasons": why}
    kind = spec.get("type") or ("http" if spec.get("url") else "stdio")
    result["transport"] = kind
    if kind == "stdio":
        result["command"] = re.sub(r"//[^/@\s]+@", "//<redacted>@", str(spec.get("command", "")))
        clean_args = []
        redact_next = False
        for arg in spec.get("args") or []:
            value = str(arg)
            if redact_next or SECRET.search(value):
                clean_args.append("<redacted>")
                redact_next = value.startswith("-") and "=" not in value
            else:
                clean_args.append(re.sub(r"//[^/@\s]+@", "//<redacted>@", value))
                redact_next = False
        result["args"] = clean_args
    else:
        result["url"] = re.sub(r"//[^/@\s]+@", "//<redacted>@", str(spec.get("url", "")))
    return result


def matches(data):
    output = []
    for entry in registrations(data):
        if not isinstance(entry, dict):
            continue
        why = reasons(entry)
        if why:
            output.append((entry, safe(entry, why)))
    return output


def fingerprint(found):
    raw = json.dumps([entry for entry, _ in found], sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode()).hexdigest()


def expected(entry, launcher):
    spec = transport(entry)
    return (
        entry.get("name") == "scrapling"
        and entry.get("enabled", not entry.get("disabled", False))
        and (spec.get("type") or "stdio") == "stdio"
        and spec.get("command") == launcher
        and spec.get("args") == ["run"]
        and spec.get("cwd") is None
        and spec.get("env") in (None, {})
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("report", "fingerprint", "names", "verify"))
    parser.add_argument("--launcher")
    args = parser.parse_args()
    try:
        data = json.load(sys.stdin)
        found = matches(data)
    except (ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"invalid Codex MCP JSON: {exc}", file=sys.stderr)
        return 8
    if args.mode == "report":
        print(json.dumps([item for _, item in found], indent=2, sort_keys=True))
    elif args.mode == "fingerprint":
        print(f"{len(found)} {fingerprint(found)}")
    elif args.mode == "names":
        for entry, _ in found:
            print(entry.get("name", ""))
    else:
        if not args.launcher:
            parser.error("verify requires --launcher")
        if len(found) != 1 or not expected(found[0][0], os.path.abspath(args.launcher)):
            print("expected exactly one canonical managed Scrapling registration", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

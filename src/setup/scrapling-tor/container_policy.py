#!/usr/bin/env python3
"""Fail-closed classification for Basix Scrapling runtime containers."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any


LABEL = "io.basix.scrapling-tor.managed"
INTERNAL = "basix-scrapling-internal"
EGRESS = "basix-tor-egress"
PYTHON = "/app/.venv/bin/python"
POLICY = "/opt/basix/policy_mcp.py"


def sequence(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [str(item) for item in value]
    return []


def normalized_image(value: Any) -> str:
    result = str(value or "").lower()
    if len(result) == 64 and all(char in "0123456789abcdef" for char in result):
        return "sha256:" + result
    return result


def base(container: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    return container.get("Config") or {}, container.get("HostConfig") or {}


def dropped_all(container: dict[str, Any], config: dict[str, Any], host: dict[str, Any]) -> bool:
    drops = {item.upper().removeprefix("CAP_") for item in sequence(host.get("CapDrop"))}
    create = sequence(config.get("CreateCommand"))
    requested = "ALL" in drops or "--cap-drop=ALL" in create or any(
        create[index] == "--cap-drop" and create[index + 1].upper() == "ALL"
        for index in range(len(create) - 1)
    )
    effective = container.get("EffectiveCaps")
    bounding = container.get("BoundingCaps")
    observed_empty = (
        "EffectiveCaps" in container
        and "BoundingCaps" in container
        and not sequence(effective)
        and not sequence(bounding)
    )
    return requested and (observed_empty or "ALL" in drops or len(drops) >= 10)


def secure_base(container: dict[str, Any]) -> bool:
    config, host = base(container)
    security = sequence(host.get("SecurityOpt"))
    return (
        (config.get("Labels") or {}).get(LABEL) == "true"
        and host.get("Privileged") is False
        and not sequence(host.get("CapAdd"))
        and dropped_all(container, config, host)
        and any(item.lower() in ("no-new-privileges", "no-new-privileges=true") for item in security)
    )


def env_map(config: dict[str, Any]) -> dict[str, str]:
    return dict(item.split("=", 1) for item in sequence(config.get("Env")) if "=" in item)


def proxy_env_valid(config: dict[str, Any], require_port: str | None, require_tor_ip: str | None = None) -> bool:
    env = env_map(config)
    tor_ip = env.get("BASIX_TOR_IP", "")
    if not tor_ip or env.get("NO_PROXY") != "" or env.get("no_proxy") != "":
        return False
    if require_tor_ip is not None and tor_ip != require_tor_ip:
        return False
    if require_port is not None and env.get("BASIX_PORT") != require_port:
        return False
    proxy = f"socks5h://{tor_ip}:9050"
    return all(env.get(key) == proxy for key in (
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"
    ))


def policy_mount_valid(container: dict[str, Any], source: str) -> bool:
    mounts = container.get("Mounts") or []
    if not isinstance(mounts, list) or len(mounts) != 1 or not isinstance(mounts[0], dict):
        return False
    mount = mounts[0]
    actual_source = os.path.realpath(str(mount.get("Source") or ""))
    return mount.get("Destination") == POLICY and mount.get("RW") is False and actual_source == os.path.realpath(source)


def legacy(container: dict[str, Any], source: str) -> bool:
    config, host = base(container)
    annotations = config.get("Annotations") or {}
    networks = set(((container.get("NetworkSettings") or {}).get("Networks") or {}))
    restart = (host.get("RestartPolicy") or {}).get("Name")
    image_name = container.get("ImageName")
    autoremove = host.get("AutoRemove") is True
    if "AutoRemove" not in host:
        autoremove = str(annotations.get("io.podman.annotations.autoremove", "")).upper() == "TRUE"
    return (
        secure_base(container)
        and networks == {INTERNAL}
        and not (host.get("PortBindings") or {})
        and not bool(host.get("PublishAllPorts"))
        and policy_mount_valid(container, source)
        and proxy_env_valid(config, None)
        and sequence(config.get("Entrypoint")) == [PYTHON]
        and sequence(config.get("Cmd")) == [POLICY]
        and autoremove
        and restart in (None, "")
        and bool(re.fullmatch(r"docker\.io/pyd4vinci/scrapling@sha256:[0-9a-fA-F]{64}", str(config.get("Image") or "")))
        and (image_name is None or str(image_name).lower() == str(config.get("Image") or "").lower())
    )


def scrapling_related(container: dict[str, Any]) -> bool:
    config, _ = base(container)
    command = " ".join(sequence(config.get("Entrypoint")) + sequence(config.get("Cmd"))).lower()
    image = str(config.get("Image") or container.get("ImageName") or "").lower()
    return (config.get("Labels") or {}).get(LABEL) == "true" or "scrapling" in image or "policy_mcp.py" in command


def managed(container: dict[str, Any], args: argparse.Namespace) -> int:
    config, host = base(container)
    networks = set(((container.get("NetworkSettings") or {}).get("Networks") or {}))
    restart = (host.get("RestartPolicy") or {}).get("Name")
    if not secure_base(container) or restart not in (None, "", "unless-stopped"):
        return 1
    if args.kind == "tor":
        health = config.get("Healthcheck") or {}
        expected = ["CMD-SHELL", "grep -q 'Bootstrapped 100%' /var/log/tor/notices.log"]
        valid = networks == {EGRESS, INTERNAL} and not (container.get("Mounts") or []) and not (host.get("PortBindings") or {}) and health.get("Test") == expected
    else:
        ports = {args.port + "/tcp": [{"HostIp": "127.0.0.1", "HostPort": args.port}]}
        valid = networks == {INTERNAL} and host.get("PortBindings") == ports and policy_mount_valid(container, args.policy) and proxy_env_valid(config, args.port, args.tor_ip) and sequence(config.get("Entrypoint")) == [PYTHON] and sequence(config.get("Cmd")) == [POLICY]
    if not valid:
        return 1
    exact = restart == "unless-stopped" and normalized_image(container.get("Image")) == normalized_image(args.actual) and normalized_image(config.get("Image")) == normalized_image(args.configured)
    return 0 if exact else 10


def load() -> dict[str, Any]:
    value = json.load(sys.stdin)
    if isinstance(value, list) and len(value) == 1:
        value = value[0]
    if not isinstance(value, dict):
        raise ValueError("inspect must contain exactly one object")
    return value


def inspect_complete(container: dict[str, Any]) -> bool:
    required = ("Config", "HostConfig", "NetworkSettings", "Mounts")
    return all(key in container and isinstance(container[key], (dict, list)) for key in required)


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="action", required=True)
    candidate = sub.add_parser("candidate")
    candidate.add_argument("--id", required=True)
    candidate.add_argument("--policy", required=True)
    managed_parser = sub.add_parser("managed")
    managed_parser.add_argument("kind", choices=("tor", "scrapling"))
    managed_parser.add_argument("--configured", required=True)
    managed_parser.add_argument("--actual", required=True)
    managed_parser.add_argument("--port", required=True)
    managed_parser.add_argument("--policy", default="")
    managed_parser.add_argument("--tor-ip")
    args = parser.parse_args()
    try:
        container = load()
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        print(f"invalid inspect data: {error}", file=sys.stderr)
        return 1
    if args.action == "managed":
        return managed(container, args)
    actual_id = str(container.get("Id") or container.get("ID") or "")
    if actual_id != args.id:
        return 1
    if not inspect_complete(container):
        print("incomplete inspect data", file=sys.stderr)
        return 7
    if legacy(container, args.policy):
        print("managed-legacy")
        return 0
    if scrapling_related(container):
        print("foreign/unsafe")
        return 7
    print("unrelated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

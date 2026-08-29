#!/usr/bin/env python3
"""Fail-closed classification for Basix Scrapling runtime containers."""

from __future__ import annotations

import argparse
import ipaddress
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
TOR_HOST = "basix-tor-proxy"


def sequence(value: Any) -> list[str]:
    """Normalize scalar or list value into strings."""
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [str(item) for item in value]
    return []


def normalized_image(value: Any) -> str:
    """Normalize image value, including bare digests."""
    result = str(value or "").lower()
    if len(result) == 64 and all(char in "0123456789abcdef" for char in result):
        return "sha256:" + result
    return result


def base(container: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """Return Config and HostConfig from container."""
    return container.get("Config") or {}, container.get("HostConfig") or {}


def dropped_all(container: dict[str, Any], config: dict[str, Any], host: dict[str, Any]) -> bool:
    """Check container, config, and host evidence for all capabilities dropped."""
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
    # A count of dropped capabilities is not proof that the runtime dropped all
    # capabilities: the set is runtime/version dependent and may omit names.
    # Accept only an explicit ALL in HostConfig or verified empty effective and
    # bounding sets after the requested drop is established.
    return requested and (observed_empty or "ALL" in drops)


def secure_base(container: dict[str, Any]) -> bool:
    """Check shared ownership and security invariants on container."""
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
    """Convert config environment entries into a mapping."""
    return dict(item.split("=", 1) for item in sequence(config.get("Env")) if "=" in item)


def private_ipv4(value: str) -> bool:
    """Return whether value is a private IPv4 address."""
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    return address.version == 4 and address.is_private


def proxy_env_kind(config: dict[str, Any], require_port: str | None, require_tor_host: str = TOR_HOST) -> str | None:
    """Classify proxy variables; require_port and require_tor_host are canonical values."""
    env = env_map(config)
    tor_host = env.get("BASIX_TOR_HOST", "")
    legacy_ip = env.get("BASIX_TOR_IP", "")
    if env.get("NO_PROXY") != "" or env.get("no_proxy") != "":
        return None
    if require_port is not None and env.get("BASIX_PORT") != require_port:
        return None
    if tor_host == require_tor_host and not legacy_ip:
        proxy, kind = f"socks5h://{tor_host}:9050", "canonical"
    elif not tor_host and private_ipv4(legacy_ip):
        proxy, kind = f"socks5h://{legacy_ip}:9050", "numeric-legacy"
    else:
        return None
    if not all(env.get(key) == proxy for key in (
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"
    )):
        return None
    return kind


def proxy_env_valid(config: dict[str, Any], require_port: str | None, require_tor_host: str | None = TOR_HOST) -> bool:
    """Return whether config has valid proxies for require_port and require_tor_host."""
    expected = TOR_HOST if require_tor_host is None else require_tor_host
    return proxy_env_kind(config, require_port, expected) is not None


def policy_mount_valid(container: dict[str, Any], source: str) -> bool:
    """Check container has the exact read-only policy source mount."""
    mounts = container.get("Mounts") or []
    if not isinstance(mounts, list) or len(mounts) != 1 or not isinstance(mounts[0], dict):
        return False
    mount = mounts[0]
    actual_source = os.path.realpath(str(mount.get("Source") or ""))
    return mount.get("Destination") == POLICY and mount.get("RW") is False and actual_source == os.path.realpath(source)


def bound_loopback_port(host: dict[str, Any]) -> str | None:
    """Return the one unprivileged loopback TCP port, or reject bindings."""
    bindings = host.get("PortBindings")
    if not isinstance(bindings, dict) or len(bindings) != 1:
        return None
    key, values = next(iter(bindings.items()))
    if not isinstance(key, str) or not re.fullmatch(r"[0-9]+/tcp", key):
        return None
    port = key.split("/", 1)[0]
    if not 1024 <= int(port) <= 65535 or not isinstance(values, list) or len(values) != 1:
        return None
    binding = values[0]
    if not isinstance(binding, dict) or binding.get("HostIp") != "127.0.0.1":
        return None
    if str(binding.get("HostPort", "")) != port:
        return None
    return port


def legacy(container: dict[str, Any], source: str) -> bool:
    """Check container is a replaceable numeric-proxy legacy using source."""
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
        and proxy_env_kind(config, None) == "numeric-legacy"
        and sequence(config.get("Entrypoint")) == [PYTHON]
        and sequence(config.get("Cmd")) == [POLICY]
        and autoremove
        and restart in (None, "")
        and bool(re.fullmatch(r"docker\.io/pyd4vinci/scrapling@sha256:[0-9a-fA-F]{64}", str(config.get("Image") or "")))
        and (image_name is None or str(image_name).lower() == str(config.get("Image") or "").lower())
    )


def scrapling_related(container: dict[str, Any]) -> bool:
    """Return whether container appears related to Scrapling."""
    config, _ = base(container)
    command = " ".join(sequence(config.get("Entrypoint")) + sequence(config.get("Cmd"))).lower()
    image = str(config.get("Image") or container.get("ImageName") or "").lower()
    return (config.get("Labels") or {}).get(LABEL) == "true" or "scrapling" in image or "policy_mcp.py" in command


def managed(container: dict[str, Any], args: argparse.Namespace) -> int:
    """Classify managed container using parsed args; return policy exit code."""
    config, host = base(container)
    networks = set(((container.get("NetworkSettings") or {}).get("Networks") or {}))
    restart = (host.get("RestartPolicy") or {}).get("Name")
    if not secure_base(container) or restart not in (None, "", "unless-stopped"):
        return 1
    if args.kind == "tor":
        health = config.get("Healthcheck") or {}
        expected = ["CMD-SHELL", "grep -q 'Bootstrapped 100%' /var/log/tor/notices.log"]
        aliases = ((container.get("NetworkSettings") or {}).get("Networks") or {}).get(INTERNAL, {}).get("Aliases") or []
        valid = networks == {EGRESS, INTERNAL} and not (container.get("Mounts") or []) and not (host.get("PortBindings") or {}) and health.get("Test") == expected
    else:
        bound_port = bound_loopback_port(host)
        proxy_kind = proxy_env_kind(config, bound_port, args.tor_host) if bound_port else None
        valid = networks == {INTERNAL} and bound_port is not None and policy_mount_valid(container, args.policy) and proxy_kind is not None and sequence(config.get("Entrypoint")) == [PYTHON] and sequence(config.get("Cmd")) == [POLICY]
    if not valid:
        return 1
    exact = restart == "unless-stopped" and normalized_image(container.get("Image")) == normalized_image(args.actual) and normalized_image(config.get("Image")) == normalized_image(args.configured)
    if args.kind == "scrapling":
        exact = exact and proxy_kind == "canonical" and bound_port == args.port
    elif args.kind == "tor":
        exact = exact and TOR_HOST in aliases
    return 0 if exact else 10


def load() -> dict[str, Any]:
    """Load one inspect object from standard input."""
    value = json.load(sys.stdin)
    if isinstance(value, list) and len(value) == 1:
        value = value[0]
    if not isinstance(value, dict):
        raise ValueError("inspect must contain exactly one object")
    return value


def inspect_complete(container: dict[str, Any]) -> bool:
    """Check container includes every required inspect section."""
    required = ("Config", "HostConfig", "NetworkSettings", "Mounts")
    return all(key in container and isinstance(container[key], (dict, list)) for key in required)


def main() -> int:
    """Parse command parameters and return the classification exit code."""
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
    managed_parser.add_argument("--tor-host", default=TOR_HOST)
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

#!/usr/bin/env python3
"""Verify Streamable HTTP, policy schemas, and Tor egress without persisting IDs."""
from __future__ import annotations

import json
import os
import socket
import sys
import urllib.request
import uuid

EXPECTED_TOOLS = {
    "bulk_fetch", "bulk_get", "bulk_stealthy_fetch", "close_session", "fetch",
    "list_sessions", "make_request", "open_request_session", "open_session",
    "screenshot", "session_fetch", "session_make_request", "stealthy_fetch",
}
CLIENT_DESCRIPTION_MARKERS = (
    "calling agent is the MCP client",
    "canonical RFC 4122 UUID version 4",
    "pass it as `client_id`",
    ":param client_id:",
)
HIDDEN_ARGUMENTS = {
    "proxy", "proxy_auth", "auth", "cdp_url", "real_chrome", "executable_path",
    "additional_args", "block_webrtc", "dns_over_https", "http3", "extra_flags",
}
TOR_HOST = os.environ.get("BASIX_TOR_HOST", os.environ.get("BASIX_TOR_IP", "tor"))


def validate_local_tor(host=TOR_HOST, *, resolver=None, connector=None):
    """Validate Tor alias resolution and local SOCKS readiness.

    :param host: Stable Tor network alias.
    :param resolver: Callable resolving the alias to an IPv4 address.
    :param connector: Callable connecting to an address with a timeout.
    :return: Resolved ready address.
    """
    resolver = resolver or socket.gethostbyname
    connector = connector or socket.create_connection
    try:
        address = resolver(host)
        with connector((address, 9050), timeout=1.0):
            return address
    except (OSError, socket.timeout) as exc:
        raise RuntimeError(f"Tor alias or SOCKS readiness failed for {host}: {exc}") from exc


class MCPClient:
    def __init__(self, endpoint: str):
        self.endpoint = endpoint
        self.session_id = None
        self.client_id = str(uuid.uuid4())
        # The service is published on loopback.  Do not let a host proxy
        # intercept the installer handshake (or make a reset look like an
        # MCP failure in an unrelated proxy).
        self.proxy_handler = urllib.request.ProxyHandler({})
        self.opener = urllib.request.build_opener(self.proxy_handler)

    def send(self, payload, *, expect_response=True, phase=None):
        phase = phase or str(payload.get("method") or "request")
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        request = urllib.request.Request(self.endpoint, json.dumps(payload).encode(), headers)
        try:
            with self.opener.open(request, timeout=30) as response:
                self.session_id = response.headers.get("Mcp-Session-Id", self.session_id)
                body = response.read().decode()
        except Exception as exc:
            raise RuntimeError(f"MCP phase {phase} failed at {self.endpoint}: {exc}") from exc
        if not expect_response:
            return None
        try:
            candidates = [line[5:].strip() for line in body.splitlines() if line.startswith("data:")]
            return json.loads(candidates[-1] if candidates else body)
        except Exception as exc:
            raise RuntimeError(f"MCP phase {phase} returned invalid JSON at {self.endpoint}: {exc}") from exc


def validate_tool_inventory(endpoint, listing):
    if not isinstance(listing, dict):
        raise RuntimeError(f"MCP phase tools/list failed at {endpoint}: response was not an object")
    result = listing.get("result")
    if not isinstance(result, dict):
        raise RuntimeError(f"MCP phase tools/list failed at {endpoint}: response contained no result object")
    tools = result.get("tools")
    if tools is None:
        tools = []
    if not isinstance(tools, list):
        raise RuntimeError(f"MCP phase tools/list failed at {endpoint}: response contained no tool list")
    names = []
    for index, tool in enumerate(tools):
        if not isinstance(tool, dict):
            raise RuntimeError(
                f"MCP phase tools/list failed at {endpoint}: tool entry {index} was not an object"
            )
        name = tool.get("name")
        if not isinstance(name, str):
            raise RuntimeError(
                f"MCP phase tools/list failed at {endpoint}: tool name at index {index} was not a string"
            )
        names.append(name)
    if len(names) != len(EXPECTED_TOOLS) or set(names) != EXPECTED_TOOLS:
        raise RuntimeError(f"MCP phase tools/list failed at {endpoint}: Scrapling tool inventory is not canonical")
    for tool in tools:
        description = tool.get("description")
        if not isinstance(description, str) or not all(
            marker in description for marker in CLIENT_DESCRIPTION_MARKERS
        ):
            raise RuntimeError(
                f"MCP phase tools/list failed at {endpoint}: {tool.get('name')} does not explain MCP client_id generation"
            )
        schema = tool.get("inputSchema")
        if schema is None:
            schema = {}
        if not isinstance(schema, dict):
            raise RuntimeError(
                f"MCP phase tools/list failed at {endpoint}: inputSchema for {tool.get('name')} was not an object"
            )
        required = schema.get("required")
        if required is None:
            required = []
        if not isinstance(required, list):
            raise RuntimeError(
                f"MCP phase tools/list failed at {endpoint}: required for {tool.get('name')} was not a list"
            )
        if "client_id" not in required:
            raise RuntimeError(
                f"MCP phase tools/list failed at {endpoint}: client_id is not required by {tool.get('name')}"
            )
        properties = schema.get("properties")
        if properties is None:
            properties = {}
        if not isinstance(properties, dict):
            raise RuntimeError(
                f"MCP phase tools/list failed at {endpoint}: properties for {tool.get('name')} was not an object"
            )
        exposed = HIDDEN_ARGUMENTS.intersection(properties)
        if exposed:
            raise RuntimeError(
                f"MCP phase tools/list failed at {endpoint}: network controls exposed by "
                f"{tool.get('name')}: {sorted(exposed)}"
            )
        if tool.get("name") == "open_session" and "session_id" in properties:
            raise RuntimeError(
                f"MCP phase tools/list failed at {endpoint}: open_session exposes caller-selected session_id"
            )
    return tools


def validate_initialize(endpoint, initialized):
    if not isinstance(initialized, dict) or not isinstance(initialized.get("result"), dict):
        raise RuntimeError(f"MCP phase initialize failed at {endpoint}: MCP initialize returned no result")
    return initialized


def validate_tor_result(endpoint, called):
    def contains_marker(value):
        if isinstance(value, dict):
            return value.get("IsTor") is True or any(contains_marker(item) for item in value.values())
        if isinstance(value, list):
            return any(contains_marker(item) for item in value)
        if isinstance(value, str):
            try:
                return contains_marker(json.loads(value))
            except (TypeError, ValueError):
                return False
        return False

    if not contains_marker(called):
        raise RuntimeError(f"MCP phase tools/call failed at {endpoint}: Scrapling tool call did not report IsTor=true")
    return called


def main():
    endpoint = sys.argv[1]
    local_only = len(sys.argv) > 2 and sys.argv[2] == "--local-ready"
    mcp_only = len(sys.argv) > 2 and sys.argv[2] == "--mcp-only"
    client = MCPClient(endpoint)
    initialized = client.send({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                   "clientInfo": {"name": "basix-installer", "version": "1"}},
    }, phase="initialize")
    validate_initialize(endpoint, initialized)
    client.send({"jsonrpc": "2.0", "method": "notifications/initialized"},
                expect_response=False, phase="notifications/initialized")
    listing = client.send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
                          phase="tools/list")
    tools = validate_tool_inventory(endpoint, listing)
    if local_only:
        validate_local_tor()
        return
    if mcp_only:
        return
    called = client.send({
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "make_request", "arguments": {
            "url": "https://check.torproject.org/api/ip", "client_id": client.client_id,
        }},
    }, phase="tools/call")
    validate_tor_result(endpoint, called)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"MCP HTTP, schema, or Tor verification failed: {exc}", file=sys.stderr)
        raise SystemExit(9)

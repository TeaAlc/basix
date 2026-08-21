#!/usr/bin/env python3
"""Verify Streamable HTTP, policy schemas, and Tor egress without persisting IDs."""
from __future__ import annotations

import json
import sys
import urllib.request
import uuid

EXPECTED_TOOLS = {
    "open_session", "close_session", "list_sessions", "get", "bulk_get",
    "fetch", "bulk_fetch", "stealthy_fetch", "bulk_stealthy_fetch", "screenshot",
}
HIDDEN_ARGUMENTS = {
    "proxy", "proxy_auth", "cdp_url", "real_chrome", "executable_path",
    "additional_args", "block_webrtc", "dns_over_https", "http3", "extra_flags",
}


class MCPClient:
    def __init__(self, endpoint: str):
        self.endpoint = endpoint
        self.session_id = None
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
    if '"IsTor":true' not in json.dumps(called, separators=(",", ":")):
        raise RuntimeError(f"MCP phase tools/call failed at {endpoint}: Scrapling tool call did not report IsTor=true")
    return called


def main():
    endpoint = sys.argv[1]
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
    capability = str(uuid.uuid4())
    called = client.send({
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "get", "arguments": {
            "url": "https://check.torproject.org/api/ip", "client_id": capability,
        }},
    }, phase="tools/call")
    validate_tor_result(endpoint, called)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"MCP HTTP, schema, or Tor verification failed: {exc}", file=sys.stderr)
        raise SystemExit(9)

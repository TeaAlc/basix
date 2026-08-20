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

    def send(self, payload, *, expect_response=True):
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        request = urllib.request.Request(self.endpoint, json.dumps(payload).encode(), headers)
        with urllib.request.urlopen(request, timeout=30) as response:
            self.session_id = response.headers.get("Mcp-Session-Id", self.session_id)
            body = response.read().decode()
        if not expect_response:
            return None
        candidates = [line[5:].strip() for line in body.splitlines() if line.startswith("data:")]
        return json.loads(candidates[-1] if candidates else body)


def main():
    endpoint = sys.argv[1]
    client = MCPClient(endpoint)
    initialized = client.send({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                   "clientInfo": {"name": "basix-installer", "version": "1"}},
    })
    if not isinstance(initialized.get("result"), dict):
        raise RuntimeError("MCP initialize returned no result")
    client.send({"jsonrpc": "2.0", "method": "notifications/initialized"}, expect_response=False)
    listing = client.send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    tools = (listing.get("result") or {}).get("tools") or []
    if {tool.get("name") for tool in tools} != EXPECTED_TOOLS:
        raise RuntimeError("Scrapling tool inventory is not canonical")
    for tool in tools:
        schema = tool.get("inputSchema") or {}
        if "client_id" not in (schema.get("required") or []):
            raise RuntimeError(f"client_id is not required by {tool.get('name')}")
        properties = schema.get("properties") or {}
        exposed = HIDDEN_ARGUMENTS.intersection(properties)
        if exposed:
            raise RuntimeError(f"network controls exposed by {tool.get('name')}: {sorted(exposed)}")
        if tool.get("name") == "open_session" and "session_id" in properties:
            raise RuntimeError("open_session exposes caller-selected session_id")
    capability = str(uuid.uuid4())
    called = client.send({
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "get", "arguments": {
            "url": "https://check.torproject.org/api/ip", "client_id": capability,
        }},
    })
    if '"IsTor":true' not in json.dumps(called, separators=(",", ":")):
        raise RuntimeError("Scrapling tool call did not report IsTor=true")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"MCP HTTP, schema, or Tor verification failed: {exc}", file=sys.stderr)
        raise SystemExit(9)

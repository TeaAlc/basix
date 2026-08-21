#!/usr/bin/env python3
"""Unit tests for the installer MCP transport diagnostics."""

import importlib.util
import pathlib
import urllib.request
import unittest
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[3]
SOURCE = ROOT / "src/setup/scrapling-tor/health_check.py"
spec = importlib.util.spec_from_file_location("health_check", SOURCE)
health_check = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(health_check)


class ResettingOpener:
    def open(self, request, timeout):
        raise ConnectionResetError(104, "Connection reset by peer")


class InvalidJsonResponse:
    headers = {}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return b"not-json"


class InvalidJsonOpener:
    def open(self, request, timeout):
        return InvalidJsonResponse()


class HealthCheckTests(unittest.TestCase):
    endpoint = "http://127.0.0.1:8002/mcp"

    def canonical_listing(self):
        return {
            "result": {
                "tools": [
                    {
                        "name": name,
                        "description": (
                            "The calling agent is the MCP client. Generate a canonical RFC 4122 "
                            "UUID version 4 and pass it as `client_id`."
                        ),
                        "inputSchema": {"required": ["client_id"], "properties": {}},
                    }
                    for name in sorted(health_check.EXPECTED_TOOLS)
                ]
            }
        }

    def test_loopback_client_uses_an_empty_proxy_handler(self):
        client = health_check.MCPClient(self.endpoint)
        self.assertIsInstance(client.proxy_handler, urllib.request.ProxyHandler)
        self.assertEqual(client.proxy_handler.proxies, {})
        self.assertEqual(uuid.UUID(client.client_id).version, 4)

    def test_connection_reset_names_each_mcp_phase_and_endpoint(self):
        for phase in ("initialize", "tools/list", "tools/call"):
            with self.subTest(phase=phase):
                client = health_check.MCPClient(self.endpoint)
                client.opener = ResettingOpener()
                with self.assertRaisesRegex(
                    RuntimeError,
                    rf"MCP phase {phase} failed at {self.endpoint}:.*Connection reset by peer",
                ):
                    client.send({"method": phase}, phase=phase)

    def test_invalid_response_names_the_mcp_phase_and_endpoint(self):
        client = health_check.MCPClient(self.endpoint)
        client.opener = InvalidJsonOpener()
        with self.assertRaisesRegex(
            RuntimeError,
            rf"MCP phase tools/list returned invalid JSON at {self.endpoint}",
        ):
            client.send({"method": "tools/list"}, phase="tools/list")

    def test_malformed_tool_entries_name_the_tools_list_phase_and_endpoint(self):
        malformed = []
        listing = self.canonical_listing()
        listing["result"]["tools"][0] = None
        malformed.append(listing)
        for key, value in (("inputSchema", []), ("name", [])):
            listing = self.canonical_listing()
            listing["result"]["tools"][0][key] = value
            malformed.append(listing)
        listing = self.canonical_listing()
        listing["result"]["tools"][0]["inputSchema"]["properties"] = []
        malformed.append(listing)
        listing = self.canonical_listing()
        listing["result"]["tools"].append(dict(listing["result"]["tools"][0]))
        malformed.append(listing)
        for listing in malformed:
            with self.subTest(listing=listing):
                with self.assertRaisesRegex(
                    RuntimeError,
                    rf"MCP phase tools/list failed at {self.endpoint}",
                ):
                    health_check.validate_tool_inventory(self.endpoint, listing)

    def test_initialize_and_tor_policy_failures_name_their_phases_and_endpoint(self):
        with self.assertRaisesRegex(RuntimeError, rf"MCP phase initialize failed at {self.endpoint}"):
            health_check.validate_initialize(self.endpoint, {"result": []})
        with self.assertRaisesRegex(RuntimeError, rf"MCP phase tools/call failed at {self.endpoint}"):
            health_check.validate_tor_result(self.endpoint, {"result": {"content": []}})

    def test_tool_descriptions_explain_client_id_generation(self):
        listing = self.canonical_listing()
        health_check.validate_tool_inventory(self.endpoint, listing)
        listing["result"]["tools"][0]["description"] = "missing client guidance"
        with self.assertRaisesRegex(RuntimeError, "does not explain MCP client_id generation"):
            health_check.validate_tool_inventory(self.endpoint, listing)

    def test_tor_policy_accepts_nested_json_text_marker(self):
        health_check.validate_tor_result(self.endpoint, {
            "result": {"content": [{"type": "text", "text": '{\n  "IsTor": true\n}'}]}
        })


if __name__ == "__main__":
    unittest.main()

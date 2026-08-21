#!/usr/bin/env python3
import asyncio
import importlib.util
import inspect
import os
import sys
import types
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class FakeMCP:
    async def list_tools(self):
        return [types.SimpleNamespace(name=name) for name in sorted(policy.EXPECTED_TOOLS)]


class FakeServer:
    def __init__(self):
        self.sessions = []
        self.next_id = 0
        self.singular_calls = []

    async def get(self, url, proxy=None, proxy_auth=None, http3=True): return proxy, proxy_auth, http3
    async def bulk_fetch(self, urls, proxy=None, cdp_url=None, real_chrome=False, executable_path=None,
                         additional_args=None, block_webrtc=False, session_id=None):
        await asyncio.sleep(0)
        return [(proxy, session_id) for _ in urls]
    async def fetch(self, url, proxy=None, cdp_url=None, real_chrome=False, executable_path=None,
                    additional_args=None, block_webrtc=False, session_id=None):
        self.singular_calls.append("fetch")
        return (await self.bulk_fetch(
            urls=[url], proxy=proxy, cdp_url=cdp_url, real_chrome=real_chrome,
            executable_path=executable_path, additional_args=additional_args,
            block_webrtc=block_webrtc, session_id=session_id,
        ))[0]
    async def open_session(self, session_type, session_id=None, proxy=None, cdp_url=None,
                           real_chrome=False, executable_path=None, additional_args=None,
                           block_webrtc=False):
        self.next_id += 1
        session = {"session_id": f"server-{self.next_id}", "type": session_type}
        self.sessions.append(session)
        return session
    async def close_session(self, session_id):
        self.sessions = [item for item in self.sessions if item["session_id"] != session_id]
        return {"closed": session_id}
    async def list_sessions(self): return list(self.sessions)
    async def screenshot(self, url, session_id=None): return url, session_id
    async def bulk_get(self, urls, proxy=None, proxy_auth=None, http3=True):
        return [await self.get(url, proxy, proxy_auth, http3) for url in urls]
    async def bulk_stealthy_fetch(self, urls, proxy=None, cdp_url=None, real_chrome=False,
                                  executable_path=None, additional_args=None, block_webrtc=False,
                                  session_id=None):
        await asyncio.sleep(0)
        return [(proxy, session_id) for _ in urls]
    async def stealthy_fetch(self, url, proxy=None, cdp_url=None, real_chrome=False, executable_path=None,
                             additional_args=None, block_webrtc=False, session_id=None):
        self.singular_calls.append("stealthy_fetch")
        return (await self.bulk_stealthy_fetch(
            urls=[url], proxy=proxy, cdp_url=cdp_url, real_chrome=real_chrome,
            executable_path=executable_path, additional_args=additional_args,
            block_webrtc=block_webrtc, session_id=session_id,
        ))[0]
    def _build_server(self, host, port): return FakeMCP()
    def serve(self, http, host, port, allowed_hosts=()):
        return http, host, port, allowed_hosts


fake_base = types.ModuleType("scrapling.engines._browsers._base")
fake_base.DEFAULT_ARGS = ()
fake_base.STEALTH_ARGS = ()
modules = {
    "scrapling": types.ModuleType("scrapling"),
    "scrapling.core": types.ModuleType("scrapling.core"),
    "scrapling.core.ai": types.ModuleType("scrapling.core.ai"),
    "scrapling.engines": types.ModuleType("scrapling.engines"),
    "scrapling.engines._browsers": types.ModuleType("scrapling.engines._browsers"),
    "scrapling.engines._browsers._base": fake_base,
}
modules["scrapling.core.ai"].ScraplingMCPServer = FakeServer
modules["scrapling.engines._browsers"]._base = fake_base
sys.modules.update(modules)
os.environ["BASIX_TOR_IP"] = "10.77.0.2"
os.environ["BASIX_PORT"] = "8002"
spec = importlib.util.spec_from_file_location("policy", ROOT / "src/setup/scrapling-tor/policy_mcp.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class PolicyTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.server = FakeServer()
        policy.assert_upstream_tools(self.server)
        self.owner = policy.configure_server(self.server)
        self.client = str(uuid.uuid4())
        self.other = str(uuid.uuid4())

    def test_every_tool_requires_client_id_and_hides_controls(self):
        for name in policy.EXPECTED_TOOLS:
            signature = inspect.signature(getattr(self.server, name))
            self.assertIn("client_id", signature.parameters, name)
            self.assertEqual(signature.parameters["client_id"].default, inspect.Parameter.empty)
            self.assertTrue(policy.NETWORK_OVERRIDES.isdisjoint(signature.parameters), name)
            description = inspect.getdoc(getattr(self.server, name))
            self.assertIn("calling agent is the MCP client", description)
            self.assertIn("canonical RFC 4122 UUID version 4", description)
        self.assertNotIn("session_id", inspect.signature(self.server.open_session).parameters)

    async def test_invalid_client_id_is_rejected_before_tool(self):
        for value in (None, "", str(uuid.uuid1()), self.client.upper()):
            with self.assertRaisesRegex(ValueError, "canonical UUID v4"):
                await self.server.get("https://example", client_id=value)
            with self.assertRaisesRegex(ValueError, "canonical UUID v4"):
                await self.server.fetch("https://example", client_id=value)
        with self.assertRaises(TypeError):
            await self.server.get("https://example")

    async def test_network_policy_remains_forced(self):
        result = await self.server.get(
            "https://example", proxy="http://evil", http3=True, client_id=self.client
        )
        self.assertEqual(result, ("socks5h://10.77.0.2:9050", None, False))

    async def test_singular_browser_aliases_forward_client_id_through_bulk_policy(self):
        result = await self.server.fetch(
            "https://example", proxy="http://evil", block_webrtc=False, client_id=self.client
        )
        self.assertEqual(result, ("socks5://10.77.0.2:9050", None))
        self.assertEqual(self.server.singular_calls, [])
        stealthy = await self.server.stealthy_fetch("https://example", client_id=self.client)
        self.assertEqual(stealthy, ("socks5://10.77.0.2:9050", None))
        self.assertEqual(self.server.singular_calls, [])

    async def test_session_lifecycle_is_private_and_server_named(self):
        opened = await self.server.open_session(
            "stealthy", session_id="caller-chosen", client_id=self.client
        )
        session_id = opened["session_id"]
        self.assertNotEqual(session_id, "caller-chosen")
        self.assertEqual(await self.server.list_sessions(client_id=self.client), [opened])
        self.assertEqual(await self.server.list_sessions(client_id=self.other), [])
        self.assertEqual(
            await self.server.fetch("https://example", session_id=session_id, client_id=self.other),
            policy.SESSION_UNAVAILABLE,
        )
        self.assertEqual(
            await self.server.fetch("https://example", session_id="unknown", client_id=self.client),
            policy.SESSION_UNAVAILABLE,
        )
        self.assertEqual(
            await self.server.fetch("https://example", session_id=session_id, client_id=self.client),
            (None, session_id),
        )
        await self.server.close_session(session_id, client_id=self.client)
        self.assertEqual(await self.server.list_sessions(client_id=self.client), [])
        self.assertEqual(
            await self.server.close_session(session_id, client_id=self.client),
            policy.SESSION_UNAVAILABLE,
        )

    async def test_same_client_can_share_and_sessions_run_concurrently(self):
        first, second = await asyncio.gather(
            self.server.open_session("first", client_id=self.client),
            self.server.open_session("second", client_id=self.client),
        )
        results = await asyncio.gather(
            self.server.fetch("https://one", session_id=first["session_id"], client_id=self.client),
            self.server.fetch("https://two", session_id=second["session_id"], client_id=self.client),
        )
        self.assertEqual({item[1] for item in results}, {first["session_id"], second["session_id"]})

    def test_http_listener_uses_exact_loopback_host_allowlist(self):
        source = inspect.getsource(policy.main)
        self.assertIn('host="0.0.0.0"', source)
        self.assertIn('f"127.0.0.1:{PORT}"', source)
        self.assertIn('f"localhost:{PORT}"', source)


if __name__ == "__main__":
    unittest.main()

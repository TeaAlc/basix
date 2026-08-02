#!/usr/bin/env python3
import asyncio
import importlib.util
import inspect
import os
import sys
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class FakeMCP:
    async def list_tools(self):
        return [types.SimpleNamespace(name=name) for name in sorted(policy.EXPECTED_TOOLS)]


class FakeServer:
    async def get(self, url, proxy=None, proxy_auth=None, http3=True): return proxy, proxy_auth, http3
    async def fetch(self, url, proxy=None, cdp_url=None, real_chrome=False, executable_path=None,
                    additional_args=None, block_webrtc=False, session_id=None):
        return proxy, session_id
    async def open_session(self, session_type, proxy=None, cdp_url=None, real_chrome=False,
                           executable_path=None, additional_args=None, block_webrtc=False):
        return proxy, block_webrtc
    async def close_session(self, session_id): return session_id
    async def list_sessions(self): return []
    async def screenshot(self, url, session_id): return url, session_id
    bulk_get = get
    bulk_fetch = fetch
    stealthy_fetch = fetch
    bulk_stealthy_fetch = fetch
    def _build_server(self, host, port): return FakeMCP()


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
spec = importlib.util.spec_from_file_location("policy", ROOT / "src/setup/scrapling-tor/policy_mcp.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class PolicyTests(unittest.TestCase):
    def test_static_tool_allowlist_is_exact(self):
        self.assertEqual(len(policy.EXPECTED_TOOLS), 10)
        policy.assert_upstream_tools(FakeServer())

    def test_http_schema_hides_and_forces_network_controls(self):
        wrapped = policy.enforce(FakeServer().get, forced={"http3": False})
        self.assertTrue({"proxy", "proxy_auth", "http3"}.isdisjoint(inspect.signature(wrapped).parameters))
        self.assertEqual(asyncio.run(wrapped("https://example", proxy="http://evil", http3=True)),
                         ("socks5h://10.77.0.2:9050", None, False))

    def test_one_shot_browser_forces_tor_but_session_does_not_reinject(self):
        wrapped = policy.enforce(FakeServer().fetch, browser=True, session_aware=True)
        self.assertTrue(policy.NETWORK_OVERRIDES.isdisjoint(inspect.signature(wrapped).parameters))
        self.assertEqual(asyncio.run(wrapped("https://example", proxy="http://evil")),
                         ("socks5://10.77.0.2:9050", None))
        self.assertEqual(asyncio.run(wrapped("https://example", proxy="http://evil", session_id="kept")),
                         (None, "kept"))

    def test_open_session_forces_tor_and_webrtc(self):
        wrapped = policy.enforce(FakeServer().open_session, browser=True, forced={"block_webrtc": True})
        self.assertEqual(asyncio.run(wrapped("stealthy", proxy="http://evil", block_webrtc=False)),
                         ("socks5://10.77.0.2:9050", True))


if __name__ == "__main__":
    unittest.main()

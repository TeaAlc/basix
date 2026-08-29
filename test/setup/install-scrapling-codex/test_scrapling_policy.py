#!/usr/bin/env python3
import asyncio
import importlib.util
import inspect
import os
import sys
import types
import unittest
import urllib.error
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
        self.opened_proxies = []
        self.opened_session_ids = []

    async def make_request(self, url, method="GET", proxy=None, proxy_auth=None, auth=None,
                           http3=True):
        return proxy, proxy_auth, auth, http3
    async def open_request_session(self, session_id=None, impersonate=None, proxy=None):
        self.opened_session_ids.append(session_id)
        self.next_id += 1
        session = {"session_id": f"server-{self.next_id}", "type": "request"}
        self.sessions.append(session)
        return session
    async def session_make_request(self, url, session_id, method="GET", auth=None, http3=True):
        return url, session_id, auth, http3
    async def bulk_fetch(self, urls, proxy=None, cdp_url=None, real_chrome=False, executable_path=None,
                         additional_args=None, block_webrtc=False):
        await asyncio.sleep(0)
        return [(proxy, None) for _ in urls]
    async def fetch(self, url, proxy=None, cdp_url=None, real_chrome=False, executable_path=None,
                    additional_args=None, block_webrtc=False):
        self.singular_calls.append("fetch")
        return (await self.bulk_fetch(
            urls=[url], proxy=proxy, cdp_url=cdp_url, real_chrome=real_chrome,
            executable_path=executable_path, additional_args=additional_args,
            block_webrtc=block_webrtc,
        ))[0]
    async def open_session(self, session_type, session_id=None, proxy=None, cdp_url=None,
                           real_chrome=False, executable_path=None, additional_args=None,
                           block_webrtc=False):
        self.opened_proxies.append(proxy)
        self.opened_session_ids.append(session_id)
        self.next_id += 1
        session = {"session_id": f"server-{self.next_id}", "type": session_type}
        self.sessions.append(session)
        return session
    async def close_session(self, session_id):
        self.sessions = [item for item in self.sessions if item["session_id"] != session_id]
        return {"closed": session_id}
    async def list_sessions(self): return list(self.sessions)
    async def session_fetch(self, url, session_id, extra_headers=None, blocked_domains=None,
                            solve_cloudflare=False): return url, session_id
    async def screenshot(self, url, session_id): return url, session_id
    async def bulk_get(self, urls, proxy=None, proxy_auth=None, auth=None, http3=True):
        return [await self.make_request(url, proxy=proxy, proxy_auth=proxy_auth,
                                        auth=auth, http3=http3) for url in urls]
    async def bulk_stealthy_fetch(self, urls, proxy=None, cdp_url=None, real_chrome=False,
                                  executable_path=None, additional_args=None, block_webrtc=False,
                                  session_id_ignored=None):
        await asyncio.sleep(0)
        return [(proxy, None) for _ in urls]
    async def stealthy_fetch(self, url, proxy=None, cdp_url=None, real_chrome=False, executable_path=None,
                             additional_args=None, block_webrtc=False):
        self.singular_calls.append("stealthy_fetch")
        return (await self.bulk_stealthy_fetch(
            urls=[url], proxy=proxy, cdp_url=cdp_url, real_chrome=real_chrome,
            executable_path=executable_path, additional_args=additional_args,
            block_webrtc=block_webrtc,
        ))[0]
    def _build_server(self, host, port): return FakeMCP()
    def serve(self, http, host, port, allowed_hosts=(), allow_unauthenticated=False):
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
            self.assertIn(":param client_id:", description)
        self.assertIn("single-URL variant", inspect.getdoc(self.server.fetch))
        self.assertIn("multi-URL variant", inspect.getdoc(self.server.bulk_fetch))
        self.assertIn("single-URL variant", inspect.getdoc(self.server.stealthy_fetch))
        self.assertIn("multi-URL variant", inspect.getdoc(self.server.bulk_stealthy_fetch))
        self.assertNotIn("session_id", inspect.signature(self.server.open_session).parameters)

    async def test_invalid_client_id_is_rejected_before_tool(self):
        for value in (None, "", str(uuid.uuid1()), self.client.upper()):
            with self.assertRaisesRegex(ValueError, "canonical UUID v4"):
                await self.server.make_request("https://example", client_id=value)
            with self.assertRaisesRegex(ValueError, "canonical UUID v4"):
                await self.server.fetch("https://example", client_id=value)
        with self.assertRaises(TypeError):
            await self.server.make_request("https://example")

    def test_configuration_accepts_only_canonical_alias_or_private_legacy_ip(self):
        original = policy.TOR_HOST
        try:
            for value in ("evil.example", "8.8.8.8", "2001:db8::1"):
                policy.TOR_HOST = value
                with self.subTest(value=value):
                    with self.assertRaisesRegex(RuntimeError, "BASIX_TOR_HOST"):
                        policy.validate_configuration()
            for value in ("basix-tor-proxy", "10.77.0.2"):
                policy.TOR_HOST = value
                with self.subTest(value=value):
                    policy.validate_configuration()
        finally:
            policy.TOR_HOST = original

    async def test_network_policy_remains_forced(self):
        result = await self.server.make_request(
            "https://example", proxy="http://evil", auth=("bad", "secret"),
            http3=True, client_id=self.client
        )
        self.assertEqual(result, ("socks5h://10.77.0.2:9050", None, None, False))

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
            "stealthy", "caller-chosen", client_id=self.client
        )
        session_id = opened["session_id"]
        self.assertEqual(self.server.opened_proxies, ["socks5://10.77.0.2:9050"])
        self.assertEqual(self.server.opened_session_ids, [None])
        self.assertNotEqual(session_id, "caller-chosen")
        self.assertEqual(await self.server.list_sessions(client_id=self.client), [opened])
        self.assertEqual(await self.server.list_sessions(client_id=self.other), [])
        self.assertEqual(
            await self.server.session_fetch("https://example", session_id=session_id, client_id=self.other),
            policy.SESSION_UNAVAILABLE,
        )
        self.assertEqual(
            await self.server.session_fetch("https://example", session_id="unknown", client_id=self.client),
            policy.SESSION_UNAVAILABLE,
        )
        self.assertEqual(
            await self.server.session_fetch("https://example", session_id=session_id, client_id=self.client),
            ("https://example", session_id),
        )
        await self.server.close_session(session_id, client_id=self.client)
        self.assertEqual(await self.server.list_sessions(client_id=self.client), [])
        self.assertEqual(
            await self.server.close_session(session_id, client_id=self.client),
            policy.SESSION_UNAVAILABLE,
        )

    async def test_request_session_is_owned_stable_and_disables_http3(self):
        opened = await self.server.open_request_session("caller-chosen", client_id=self.client)
        public_id = opened["session_id"]
        self.assertEqual(self.server.opened_session_ids, [None])
        self.assertEqual(
            await self.server.session_make_request(
                "https://example", public_id, auth=("bad", "secret"),
                http3=True, client_id=self.client,
            ),
            ("https://example", public_id, None, False),
        )
        self.assertEqual(
            await self.server.session_make_request(
                "https://example", public_id, client_id=self.other,
            ),
            policy.SESSION_UNAVAILABLE,
        )

    async def test_same_client_can_share_and_sessions_run_concurrently(self):
        first, second = await asyncio.gather(
            self.server.open_session("first", client_id=self.client),
            self.server.open_session("second", client_id=self.client),
        )
        results = await asyncio.gather(
            self.server.session_fetch("https://one", session_id=first["session_id"], client_id=self.client),
            self.server.session_fetch("https://two", session_id=second["session_id"], client_id=self.client),
        )
        self.assertEqual({item[1] for item in results}, {first["session_id"], second["session_id"]})

    def test_http_listener_uses_exact_loopback_host_allowlist(self):
        source = inspect.getsource(policy.main)
        self.assertIn('host="0.0.0.0"', source)
        self.assertIn('f"127.0.0.1:{PORT}"', source)
        self.assertIn('f"localhost:{PORT}"', source)

    async def test_monitor_resolves_every_five_seconds_and_tracks_generation(self):
        now = [0.0]
        addresses = ["10.77.0.2", "10.77.0.3"]
        resolutions = []
        probes = []
        monitor = policy.TorMonitor(
            "tor.alias",
            resolver=lambda host: resolutions.append(host) or addresses[0],
            probe=lambda address, port, timeout: probes.append((address, port, timeout)),
            clock=lambda: now[0],
        )
        self.assertTrue(monitor.check())
        self.assertEqual((monitor.generation, resolutions), (1, ["tor.alias"]))
        now[0] = 4.99
        self.assertTrue(monitor.check())
        self.assertEqual(len(resolutions), 1)
        addresses[0] = "10.77.0.3"
        now[0] = 5.0
        self.assertTrue(monitor.check())
        self.assertEqual(monitor.generation, 2)
        self.assertEqual(probes[-1], ("10.77.0.3", 9050, 1.0))

    async def test_monitor_increments_generation_when_same_alias_recovers(self):
        monitor = policy.TorMonitor(
            resolver=lambda _host: "10.77.0.2",
            probe=lambda *_: True,
        )
        self.assertTrue(monitor.check())
        first_generation = monitor.generation
        monitor.invalidate()
        self.assertTrue(monitor.check(force=True))
        self.assertEqual(monitor.generation, first_generation + 1)

    async def test_shared_bounded_recovery_uses_jitter_and_one_confirmation(self):
        attempts = []
        delays = []
        confirmations = []

        def probe(address, port, timeout):
            attempts.append((address, port, timeout))
            if len(attempts) < 4:
                raise ConnectionRefusedError("proxy refused")

        async def confirm():
            confirmations.append(True)
            return True

        monitor = policy.TorMonitor(
            resolver=lambda _host: "10.77.0.2", probe=probe,
            sleeper=lambda delay: delays.append(delay) or asyncio.sleep(0),
            jitter=lambda delay: delay * 1.2, confirmer=confirm,
        )
        first, second = await asyncio.gather(monitor.recover(), monitor.recover())
        self.assertEqual((first, second), (True, True))
        self.assertEqual(delays, [0.6, 1.2, 2.4])
        self.assertEqual(confirmations, [True])

    async def test_stateless_retry_is_once_and_only_for_proxy_failures(self):
        class ReadyMonitor(policy.TorMonitor):
            async def recover(self):
                self.valid = True
                return True

        monitor = ReadyMonitor(resolver=lambda _: "10.77.0.2", probe=lambda *_: True)
        calls = []

        async def transient():
            calls.append(True)
            if len(calls) == 1:
                raise ConnectionResetError("proxy reset")
            return "ok"

        self.assertEqual(await monitor.execute(transient), "ok")
        self.assertEqual(len(calls), 2)
        target_calls = []

        async def target_failure():
            target_calls.append(True)
            raise urllib.error.HTTPError("https://target", 403, "forbidden", {}, None)

        with self.assertRaises(urllib.error.HTTPError):
            await monitor.execute(target_failure)
        self.assertEqual(len(target_calls), 1)

        target_calls = []

        async def target_transport_failure():
            target_calls.append(True)
            raise ConnectionRefusedError("target server refused connection")

        with self.assertRaises(ConnectionRefusedError):
            await monitor.execute(target_transport_failure)
        self.assertEqual(len(target_calls), 1)

    async def test_browser_session_recreates_atomically_after_transport_failure(self):
        class ReadyMonitor(policy.TorMonitor):
            async def recover(self):
                self.valid = True
                return True

        monitor = ReadyMonitor(resolver=lambda _: "10.77.0.2", probe=lambda *_: True)
        server = FakeServer()
        original = server.session_fetch
        failed = [False]

        async def flaky(url, session_id, extra_headers=None, blocked_domains=None,
                        solve_cloudflare=False):
            if session_id == "server-1" and not failed[0]:
                failed[0] = True
                raise ConnectionResetError("proxy reset")
            return await original(url, session_id, extra_headers, blocked_domains, solve_cloudflare)

        server.session_fetch = flaky
        owner = policy.configure_server(server, monitor)
        opened = await server.open_session("browser", client_id=self.client)
        public_id = opened["session_id"]
        result = await server.session_fetch(
            "https://example", session_id=public_id, client_id=self.client
        )
        self.assertEqual(result, ("https://example", "server-2"))
        self.assertEqual(owner.session_state[public_id]["upstream_id"], "server-2")
        self.assertEqual((await server.list_sessions(client_id=self.client))[0], opened)

    async def test_request_session_recreates_with_stable_public_id(self):
        class ReadyMonitor(policy.TorMonitor):
            async def recover(self):
                self.valid = True
                return True

        monitor = ReadyMonitor(resolver=lambda _: "10.77.0.2", probe=lambda *_: True)
        server = FakeServer()
        original = server.session_make_request
        failed = [False]

        async def flaky(url, session_id, method="GET", auth=None, http3=True):
            if session_id == "server-1" and not failed[0]:
                failed[0] = True
                raise ConnectionResetError("proxy reset")
            return await original(url, session_id, method, auth, http3)

        server.session_make_request = flaky
        owner = policy.configure_server(server, monitor)
        opened = await server.open_request_session(client_id=self.client)
        public_id = opened["session_id"]
        result = await server.session_make_request(
            "https://example", public_id, client_id=self.client
        )
        self.assertEqual(result, ("https://example", "server-2", None, False))
        self.assertEqual(owner.session_state[public_id]["upstream_id"], "server-2")
        self.assertEqual((await server.list_sessions(client_id=self.client))[0], opened)

    async def test_session_recovery_transport_failure_is_distinct_and_bounded(self):
        class ReadyMonitor(policy.TorMonitor):
            async def recover(self):
                self.valid = True
                return True

        monitor = ReadyMonitor(resolver=lambda _: "10.77.0.2", probe=lambda *_: True)
        server = FakeServer()
        failed = [False]

        async def always_proxy_failure(url, session_id, extra_headers=None,
                                       blocked_domains=None, solve_cloudflare=False):
            if not failed[0]:
                failed[0] = True
                raise ConnectionResetError("proxy reset")
            raise ConnectionResetError("proxy still unavailable")

        server.session_fetch = always_proxy_failure
        policy.configure_server(server, monitor)
        opened = await server.open_session("browser", client_id=self.client)
        with self.assertRaisesRegex(RuntimeError, "Tor transport temporarily unavailable"):
            await server.session_fetch(
                "https://example", session_id=opened["session_id"], client_id=self.client
            )


if __name__ == "__main__":
    unittest.main()

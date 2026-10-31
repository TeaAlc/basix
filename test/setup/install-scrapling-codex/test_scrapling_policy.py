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
from unittest.mock import AsyncMock, Mock, patch

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

    def test_irrecoverable_health_only_signals_poison_or_persistent_cancel_saturation(self):
        """Transient requests and active work never request service replacement."""
        notify = Mock()
        self.owner.failure_notifier = notify
        active = [Mock(done=Mock(return_value=False), cancelling=Mock(return_value=0)) for _ in range(32)]
        self.owner.pending_operations = set(active)
        self.owner.assess_health(0)
        self.owner.assess_health(1000)
        notify.assert_not_called()
        self.owner.abandoned_operations = set(active)
        self.owner.assess_health(1001)
        self.owner.assess_health(1060)
        notify.assert_not_called()
        self.owner.assess_health(1061)
        self.owner.assess_health(1062)
        notify.assert_called_once_with()
        self.owner.pending_operations.clear()

    def test_persistent_poison_of_all_session_slots_requests_recovery(self):
        """Sixteen stuck owned sessions cannot leave the session API degraded forever."""
        self.owner.failure_notifier = Mock()
        tasks = [Mock(done=Mock(return_value=False), cancelling=Mock(return_value=1)) for _ in range(16)]
        self.owner.pending_operations = set(tasks)
        self.owner.abandoned_operations = set(tasks)
        self.owner.session_state = {str(index): {"poisoned": True, "work": task} for index, task in enumerate(tasks)}
        self.owner.assess_health(0)
        self.owner.assess_health(59)
        self.owner.failure_notifier.assert_not_called()
        self.owner.assess_health(60)
        self.owner.failure_notifier.assert_called_once_with()
        self.owner.pending_operations.clear()
        self.owner.session_state.clear()

    async def test_stuck_alias_resolution_is_nonblocking_killed_and_reaped(self):
        """A stuck libc helper cannot block unrelated loop work or cancellation."""
        original = asyncio.create_subprocess_exec
        children = []
        async def spawn(*args, **kwargs):
            """Start stuck helper. :param args: Requested command. :param kwargs: Process options."""
            child = await original(sys.executable, "-c", "import time; time.sleep(30)", **kwargs)
            children.append(child)
            return child
        monitor = policy.TorMonitor()
        with patch.object(policy.asyncio, "create_subprocess_exec", new=spawn):
            check = asyncio.create_task(monitor.check(force=True))
            for _ in range(3):
                await asyncio.sleep(.01)
            self.assertFalse(check.done())
            check.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await asyncio.wait_for(check, .5)
            self.assertIsNotNone(children[-1].returncode)
            self.assertFalse(await asyncio.wait_for(monitor.check(force=True), 2))
            self.assertIsNotNone(children[-1].returncode)

    async def test_stuck_session_work_does_not_deadlock_other_clients(self):
        """Null/huge caller timeout cannot hold lifecycle locks or leak new work slots."""
        self.owner.monitor.check = AsyncMock(return_value=True)
        self.owner.failure_notifier = Mock()
        for timeout in (None, 10**20):
            session = await self.server.open_request_session(client_id=self.client)
            identifier = session["session_id"]
            release, started = asyncio.Event(), asyncio.Event()
            self.addCleanup(release.set)
            async def stuck(url, session_id, timeout=None):
                """Ignore cancellation until released. :param url: URL. :param session_id: Upstream ID. :param timeout: Untrusted caller timeout."""
                started.set()
                while not release.is_set():
                    try:
                        await release.wait()
                    except asyncio.CancelledError:
                        asyncio.current_task().uncancel()
                        continue
            operation = self.owner.network_tool(stuck, session_aware=True)
            with patch.object(policy, "SESSION_OPERATION_TIMEOUT", .05), patch.object(policy, "SESSION_LOCK_TIMEOUT", .01), patch.object(policy, "SESSION_CLOSE_TIMEOUT", .02):
                task = asyncio.create_task(operation(url="https://example.com", session_id=identifier, timeout=timeout, client_id=self.client))
                await started.wait()
                with self.assertRaises(asyncio.TimeoutError):
                    await self.server.close_session(session_id=identifier, client_id=self.client)
                independent = await self.server.open_request_session(client_id=self.other)
                self.assertTrue(await self.server.list_sessions(client_id=self.other))
                await self.server.close_session(session_id=independent["session_id"], client_id=self.other)
                with self.assertRaisesRegex(RuntimeError, "deadline"):
                    await asyncio.wait_for(task, .2)
                self.assertTrue(self.owner.session_state[identifier]["poisoned"])
                self.assertEqual(len(self.owner.abandoned_operations), 1)
                self.assertEqual(await self.server.close_session(session_id=identifier, client_id=self.client), policy.SESSION_UNAVAILABLE)
                release.set()
                await asyncio.sleep(0)
                await asyncio.sleep(0)
                await self.server.close_session(session_id=identifier, client_id=self.client)
            self.assertFalse(self.owner.session_state)
            self.assertFalse(self.owner.pending_operations)
            self.assertFalse(self.owner.abandoned_operations)
            self.owner.assess_health()
            self.owner.failure_notifier.assert_not_called()

    async def test_stuck_close_releases_lifecycle_for_independent_clients(self):
        """Unknown close work retains only its own bounded session slot."""
        session = await self.server.open_request_session(client_id=self.client)
        release = asyncio.Event()
        self.addCleanup(release.set)
        async def stuck_close(session_id):
            """Wait despite cancellation. :param session_id: Owned upstream identifier."""
            while not release.is_set():
                try:
                    await release.wait()
                except asyncio.CancelledError:
                    continue
            return {"closed": True}
        closing = self.owner.close_session(stuck_close)
        with patch.object(policy, "SESSION_CLOSE_TIMEOUT", .02):
            with self.assertRaises(asyncio.TimeoutError):
                await closing(session_id=session["session_id"], client_id=self.client)
            independent = await self.server.open_request_session(client_id=self.other)
            self.assertTrue(await self.server.list_sessions(client_id=self.other))
            await self.server.close_session(session_id=independent["session_id"], client_id=self.other)
            self.assertTrue(self.owner.session_state[session["session_id"]]["poisoned"])
        release.set()
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        await self.server.close_session(session_id=session["session_id"], client_id=self.client)
        self.assertFalse(self.owner.pending_operations)

    async def test_timed_out_creation_blocks_further_unknown_allocations(self):
        """Unknown cancellation state cannot accumulate upstream sessions."""
        async def opener(session_id=None, proxy=None):
            """Simulate upstream timeout. :param session_id: Ignored ID. :param proxy: Managed proxy."""
            raise asyncio.TimeoutError()
        guarded = self.owner.open_session(opener, kind="request")
        with self.assertRaisesRegex(RuntimeError, "timed out"):
            await guarded(client_id=self.client)
        with self.assertRaisesRegex(RuntimeError, "capacity"):
            await self.server.open_request_session(client_id=self.client)
        self.assertEqual(self.server.sessions, [])

    async def test_session_capacity_idle_expiry_and_repeated_cycles(self):
        """Idle closure reclaims bounded upstream and policy session state."""
        for _ in range(3):
            for _ in range(16):
                await self.server.open_request_session(client_id=self.client)
            with self.assertRaisesRegex(RuntimeError, "capacity"):
                await self.server.open_request_session(client_id=self.client)
            for state in self.owner.session_state.values():
                state["last_used"] = -3600
            await self.owner.expire_sessions()
            self.assertEqual(self.owner.session_state, {})
            self.assertEqual(self.owner.session_locks, {})
            self.assertEqual(self.owner.owners, {})
            self.assertEqual(self.server.sessions, [])

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
        with self.assertRaisesRegex(ValueError, "network overrides"):
            await self.server.make_request(
                "https://example", proxy="http://evil", auth=("bad", "secret"),
                http3=True, client_id=self.client
            )
        result = await self.server.make_request("https://example", client_id=self.client)
        self.assertEqual(result, ("socks5h://10.77.0.2:9050", None, None, False))

    async def test_singular_browser_aliases_forward_client_id_through_bulk_policy(self):
        with self.assertRaisesRegex(ValueError, "network overrides"):
            await self.server.fetch("https://example", proxy="http://evil", client_id=self.client)
        result = await self.server.fetch("https://example", client_id=self.client)
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
                "https://example", public_id, client_id=self.client,
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
        self.assertTrue(await monitor.check())
        self.assertEqual((monitor.generation, resolutions), (1, ["tor.alias"]))
        now[0] = 4.99
        self.assertTrue(await monitor.check())
        self.assertEqual(len(resolutions), 1)
        addresses[0] = "10.77.0.3"
        now[0] = 5.0
        self.assertTrue(await monitor.check())
        self.assertEqual(monitor.generation, 2)
        self.assertEqual(probes[-1], ("10.77.0.3", 9050, 1.0))

    async def test_monitor_increments_generation_when_same_alias_recovers(self):
        monitor = policy.TorMonitor(
            resolver=lambda _host: "10.77.0.2",
            probe=lambda *_: True,
        )
        self.assertTrue(await monitor.check())
        first_generation = monitor.generation
        monitor.invalidate()
        self.assertTrue(await monitor.check(force=True))
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

    async def test_failed_stateless_retry_requires_fresh_external_evidence(self):
        """Check classification, sanitization, and the two-operation budget."""
        for evidence in (True, False, RuntimeError("secret diagnostic URL"), None):
            with self.subTest(evidence=evidence):
                confirmer = None if evidence is None else AsyncMock(side_effect=[True, evidence])
                monitor = policy.TorMonitor(
                    resolver=lambda _: "10.77.0.2", probe=lambda *_: True,
                    confirmer=confirmer,
                )
                operation = AsyncMock(side_effect=ConnectionResetError(
                    "SOCKS failure https://user:secret@example.invalid/private"
                ))
                expected = policy.TOR_REQUEST_FAILED if evidence is True else policy.TOR_UNAVAILABLE
                with self.assertRaises(RuntimeError) as raised:
                    await monitor.execute(operation)
                self.assertEqual(str(raised.exception), expected["error"])
                self.assertTrue(raised.exception.__suppress_context__)
                self.assertEqual(operation.await_count, 2)
                self.assertEqual(monitor.valid, evidence is True)
                if confirmer is not None:
                    self.assertEqual(confirmer.await_count, 2)

    async def test_retry_diagnostic_timeout_is_bounded_and_sanitized(self):
        """A diagnostic that never completes cannot extend the request budget."""
        confirmations = []

        async def confirm():
            """Confirm recovery once, then simulate a stuck diagnostic."""
            confirmations.append(True)
            if len(confirmations) == 1:
                return True
            await asyncio.Future()

        monitor = policy.TorMonitor(
            resolver=lambda _: "10.77.0.2", probe=lambda *_: True, confirmer=confirm,
        )
        operation = AsyncMock(side_effect=ConnectionResetError("SOCKS secret"))
        with patch.object(policy, "TOR_CONFIRM_TIMEOUT", .01):
            with self.assertRaisesRegex(RuntimeError, "^Tor transport temporarily unavailable$"):
                await asyncio.wait_for(monitor.execute(operation), .5)
        self.assertEqual(len(confirmations), 2)
        self.assertEqual(operation.await_count, 2)
        self.assertFalse(monitor.valid)

    async def test_configured_diagnostic_uses_a_fresh_forced_tor_request(self):
        """Exercise the real confirmer wiring after the destination retry fails."""
        server = FakeServer()
        calls = []

        async def request(url, method="GET", proxy=None, proxy_auth=None, auth=None, http3=True):
            """Record the upstream request and fail only the private destination.

            :param url: Requested destination or external confirmation endpoint.
            :param method: HTTP method.
            :param proxy: Forced Tor proxy.
            :param proxy_auth: Optional proxy authentication.
            :param auth: Optional HTTP authentication.
            :param http3: Whether the HTTP/3 transport is enabled.
            """
            calls.append((url, proxy, http3))
            if url == "https://check.torproject.org/api/ip":
                return {"body": '{"IsTor":true}'}
            raise ConnectionResetError("SOCKS private URL failure")

        server.make_request = request
        owner = policy.configure_server(server)
        owner.monitor.resolver = lambda _: "10.77.0.2"
        owner.monitor.probe = lambda *_: True
        with self.assertRaisesRegex(RuntimeError, "^Request or destination failed through Tor;"):
            await server.make_request("https://private.invalid/secret", client_id=self.client)
        self.assertEqual([call[0] for call in calls], [
            "https://private.invalid/secret", "https://check.torproject.org/api/ip",
            "https://private.invalid/secret", "https://check.torproject.org/api/ip",
        ])
        self.assertTrue(all(call[1:] == (policy.HTTP_PROXY, False) for call in calls))

    async def test_failed_recovery_confirmation_stops_before_operation_retry(self):
        """Unconfirmed global recovery exposes no diagnostic or upstream secrets."""
        for evidence in (False, RuntimeError("secret diagnostic failure")):
            with self.subTest(evidence=evidence):
                confirmer = AsyncMock(side_effect=[evidence])
                monitor = policy.TorMonitor(
                    resolver=lambda _: "10.77.0.2", probe=lambda *_: True,
                    confirmer=confirmer,
                )
                operation = AsyncMock(side_effect=ConnectionResetError("SOCKS secret URL"))
                with self.assertRaisesRegex(RuntimeError, "^Tor transport temporarily unavailable$") as raised:
                    await monitor.execute(operation)
                self.assertTrue(raised.exception.__suppress_context__)
                self.assertEqual(operation.await_count, 1)
                self.assertEqual(confirmer.await_count, 1)
                self.assertFalse(monitor.valid)

    async def test_alias_loss_after_retry_invalidates_without_external_confirmation(self):
        """Fresh local failure overrides earlier successful external evidence."""
        confirmer = AsyncMock(return_value=True)
        monitor = policy.TorMonitor(
            resolver=Mock(side_effect=["10.77.0.2", OSError("alias gone")]),
            probe=lambda *_: True, confirmer=confirmer,
        )
        operation = AsyncMock(side_effect=ConnectionResetError("SOCKS failed"))
        with self.assertRaisesRegex(RuntimeError, "^Tor transport temporarily unavailable$"):
            await monitor.execute(operation)
        self.assertEqual(operation.await_count, 2)
        self.assertEqual(confirmer.await_count, 1)
        self.assertFalse(monitor.valid)

    async def test_failed_owned_session_retry_uses_fresh_evidence_and_keeps_ownership(self):
        """Both session types recreate once and classify only the retried request."""
        for kind in ("browser", "request"):
            for evidence in (True, False, RuntimeError("secret diagnostic"), None):
                with self.subTest(kind=kind, evidence=evidence):
                    confirmer = None if evidence is None else AsyncMock(side_effect=[True, evidence])
                    monitor = policy.TorMonitor(
                        resolver=lambda _: "10.77.0.2", probe=lambda *_: True,
                        confirmer=confirmer,
                    )
                    server = FakeServer()
                    calls = []

                    async def failure(url, session_id, http3=True):
                        """Fail a session request.

                        :param url: Requested destination.
                        :param session_id: Upstream session identifier.
                        :param http3: Whether the HTTP/3 transport is enabled.
                        """
                        calls.append((session_id, http3))
                        raise ConnectionResetError("ERR_SOCKS_CONNECTION_FAILED secret URL")

                    method = "session_fetch" if kind == "browser" else "session_make_request"
                    setattr(server, method, failure)
                    owner = policy.configure_server(server, monitor)
                    opened = await (server.open_session("browser", client_id=self.client)
                                    if kind == "browser" else
                                    server.open_request_session(client_id=self.client))
                    public_id = opened["session_id"]
                    request = getattr(server, method)
                    self.assertEqual(await request(
                        "https://private.invalid", public_id, client_id=self.other
                    ), policy.SESSION_UNAVAILABLE)
                    self.assertEqual(calls, [])
                    expected = policy.TOR_REQUEST_FAILED if evidence is True else policy.TOR_UNAVAILABLE
                    with self.assertRaises(RuntimeError) as raised:
                        await request("https://private.invalid", public_id, client_id=self.client)
                    self.assertEqual(str(raised.exception), expected["error"])
                    self.assertTrue(raised.exception.__suppress_context__)
                    self.assertEqual([call[0] for call in calls], ["server-1", "server-2"])
                    self.assertEqual(server.next_id, 2)
                    self.assertEqual(owner.owners[public_id], self.client)
                    self.assertEqual(owner.session_state[public_id]["upstream_id"], "server-2")
                    self.assertEqual((await server.list_sessions(client_id=self.client))[0], opened)
                    self.assertEqual(monitor.valid, evidence is True)
                    if confirmer is not None:
                        self.assertEqual(confirmer.await_count, 2)
                    if kind == "request":
                        self.assertTrue(all(call[1] is False for call in calls))

    async def test_session_recreation_proxy_failure_is_not_a_destination_diagnosis(self):
        """A failed session recreation performs no retried destination operation."""
        confirmer = AsyncMock(return_value=True)
        monitor = policy.TorMonitor(
            resolver=lambda _: "10.77.0.2", probe=lambda *_: True, confirmer=confirmer,
        )
        server = FakeServer()
        calls = []

        async def failure(url, session_id):
            """Fail the initial request.

            :param url: Requested destination.
            :param session_id: Upstream session identifier.
            """
            calls.append(session_id)
            raise ConnectionResetError("SOCKS secret request")

        server.session_fetch = failure
        owner = policy.configure_server(server, monitor)
        opened = await server.open_session("browser", client_id=self.client)
        recreate = AsyncMock(side_effect=ConnectionResetError("proxy secret recreation"))
        owner.session_state[opened["session_id"]]["method"] = recreate
        with self.assertRaisesRegex(RuntimeError, "^Tor transport temporarily unavailable$") as raised:
            await server.session_fetch(
                "https://private.invalid", opened["session_id"], client_id=self.client
            )
        self.assertTrue(raised.exception.__suppress_context__)
        self.assertEqual(calls, ["server-1"])
        self.assertEqual(recreate.await_count, 1)
        self.assertEqual(confirmer.await_count, 1)
        self.assertEqual(owner.session_state[opened["session_id"]]["upstream_id"], "server-1")
        self.assertFalse(monitor.valid)

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


class CurrentContractTests(unittest.TestCase):
    """Review exact 0.5 inventory, removed tools and forced network controls."""
    def make_server(self):
        """Build a source-signature fixture without importing external dependencies."""
        class CurrentMCP:
            """Expose supported SDK registration interfaces."""
            def __init__(self):
                """Initialize tool names."""
                self.names = set(policy.CURRENT_SIGNATURES)
            async def list_tools(self):
                """Return registered names."""
                return [types.SimpleNamespace(name=name) for name in self.names]
            def remove_tool(self, name):
                """Remove one tool. :param name: Reviewed disabled name."""
                self.names.remove(name)
        class CurrentServer:
            """Capture calls for policy assertions."""
            def __init__(self):
                """Initialize call capture."""
                self.calls = []
            def _build_server(self, host, port):
                """Build fixture. :param host: Host. :param port: Port."""
                return CurrentMCP()
        for name, parameters in policy.CURRENT_SIGNATURES.items():
            documentation = " ".join(":param " + name + ": Fixture input." for name in parameters)
            namespace = {}
            body = "async def " + name + "(self" + "".join(", " + parameter + "=None" for parameter in parameters) + "):\n"
            body += "    \"\"\"" + documentation + "\"\"\"\n    values=locals().copy()\n    values.pop('self')\n    self.calls.append(('" + name + "', values))\n"
            if name in ("browser_open", "open_request_session"):
                body += "    return {'session_id':'owned-session'}\n"
            elif name == "list_sessions":
                body += "    return [{'session_id':'owned-session'}]\n"
            else:
                body += "    return values\n"
            exec(body, namespace)
            setattr(CurrentServer, name, namespace[name])
        return CurrentServer()

    def test_current_inventory_and_signature_drift(self):
        """All 16 reviewed upstream tools are required before reduction."""
        server = self.make_server()
        policy.assert_upstream_tools(server)
        server.browser_evaluate = AsyncMock()
        with self.assertRaisesRegex(RuntimeError, "signature"):
            policy.assert_upstream_tools(server)

    def test_current_reduction_and_forced_network_policy(self):
        """Only reviewed retrieval methods remain, with ownership and no overrides."""
        server = self.make_server()
        server.list_sessions.__func__.__annotations__["return"] = list[dict]
        monitor = Mock(check=AsyncMock(return_value=True))
        async def execute(operation, **kwargs):
            """Invoke fixture operation. :param operation: Async call. :param kwargs: Retry options."""
            return await operation()
        monitor.execute = execute
        policy.configure_server(server, monitor=monitor)
        self.assertEqual(inspect.signature(server.list_sessions).return_annotation, list[dict])
        names = {tool.name for tool in asyncio.run(server._build_server("localhost", 8002).list_tools())}
        self.assertEqual(names, policy.CURRENT_PUBLIC_TOOLS)
        client = str(uuid.uuid4())
        async def exercise():
            """Assert HTTP/browser/session policy behavior."""
            request = await server.make_request(url="https://example.com", client_id=client)
            self.assertEqual(request['proxy'], policy.HTTP_PROXY)
            self.assertEqual([request[key] for key in ('http3','verify','follow_redirects','max_redirects','retries')], [False, True, 'safe', 5, 1])
            for key in ('verify','follow_redirects','max_redirects','proxy','http3'):
                with self.assertRaises(ValueError):
                    await server.make_request(url="https://example.com", client_id=client, **{key: False})
            opened = await server.browser_open(client_id=client)
            self.assertEqual(server.calls[-1][1]['proxy'], policy.BROWSER_PROXY)
            self.assertTrue(server.calls[-1][1]['block_webrtc'])
            foreign = await server.browser_fetch(url="https://example.com", session_id=opened['session_id'], client_id=str(uuid.uuid4()))
            self.assertEqual(foreign, policy.SESSION_UNAVAILABLE)
            own = await server.browser_fetch(url="https://example.com", session_id=opened['session_id'], client_id=client)
            self.assertEqual(own['session_id'], opened['session_id'])
        asyncio.run(exercise())
        for name in names:
            signature = inspect.signature(getattr(server, name))
            self.assertEqual(signature.parameters['client_id'].default, inspect.Parameter.empty)
            self.assertFalse(policy.NETWORK_OVERRIDES.intersection(signature.parameters))


if __name__ == "__main__":
    unittest.main()

"""Fail-closed, multi-client Scrapling MCP policy for the Basix Tor service."""
import asyncio
import functools
import inspect
import ipaddress
import json
import os
import re
import random
import socket
import time
import urllib.error
import uuid

from scrapling.core.ai import ScraplingMCPServer
from scrapling.engines._browsers import _base as browser_base

EXPECTED_TOOLS = {
    "bulk_fetch", "bulk_get", "bulk_stealthy_fetch", "close_session", "fetch",
    "list_sessions", "make_request", "open_request_session", "open_session",
    "screenshot", "session_fetch", "session_make_request", "stealthy_fetch",
}
NETWORK_OVERRIDES = {
    "proxy", "proxy_auth", "cdp_url", "real_chrome", "executable_path",
    "additional_args", "block_webrtc", "dns_over_https", "http3", "extra_flags",
    "auth",
}
SESSION_TOOLS = {
    "close_session", "session_fetch", "session_make_request", "screenshot",
}
TOR_HOST = os.environ.get("BASIX_TOR_HOST") or os.environ.get("BASIX_TOR_IP") or ""
PORT = int(os.environ.get("BASIX_PORT", "8002"))
HTTP_PROXY = f"socks5h://{TOR_HOST}:9050"
BROWSER_PROXY = f"socks5://{TOR_HOST}:9050"
CHROMIUM_FLAGS = (
    "--disable-quic",
    "--disable-features=WebRtcHideLocalIpsWithMdns,UseDnsHttpsSvcbAlpn",
    "--webrtc-ip-handling-policy=disable_non_proxied_udp",
    "--force-webrtc-ip-handling-policy",
)
SUSPICIOUS_NETWORK_NAME = re.compile(
    r"proxy|auth|cdp|chrome|execut|argument|webrtc|dns|http3|quic", re.I
)
SESSION_UNAVAILABLE = {"error": "session not available"}
TOR_UNAVAILABLE = {"error": "Tor transport temporarily unavailable"}
RECOVERY_DELAYS = (0.0, 0.5, 1.0, 2.0)
CLIENT_ID_GUIDANCE = (
    "The calling agent is the MCP client. Before calling this tool, generate a "
    "canonical RFC 4122 UUID version 4 with a cryptographically secure system "
    "source and pass it as `client_id`. Reuse that same ID for related calls and "
    "session lifecycle operations; do not use `default`, a `session_id`, or a "
    "server-generated placeholder. The server controls all network settings."
)
CLIENT_ID_PARAMETER = (
    ":param client_id: Required. The calling agent supplies the canonical UUID v4 "
    "used to isolate its sessions and must reuse it for related calls."
)
SINGULAR_FETCH_GUIDANCE = (
    "This is the single-URL variant of the corresponding bulk fetch tool: pass "
    "one `url`; use `bulk_fetch` or `bulk_stealthy_fetch` for multiple URLs."
)
BULK_FETCH_GUIDANCE = (
    "This is the multi-URL variant: pass `urls` as a list and keep the same "
    "`client_id` for related session calls."
)


def validate_configuration():
    """Reject unsafe environment configuration before opening the listener."""
    if not TOR_HOST or len(TOR_HOST) > 253 or not re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", TOR_HOST
    ):
        raise RuntimeError("BASIX_TOR_HOST must be basix-tor-proxy or a private IPv4 legacy value")
    try:
        address = ipaddress.ip_address(TOR_HOST)
    except ValueError:
        address = None
    if address is None and TOR_HOST != "basix-tor-proxy":
        raise RuntimeError("BASIX_TOR_HOST must be basix-tor-proxy or a private IPv4 legacy value")
    if address is not None and (address.version != 4 or not address.is_private):
        raise RuntimeError("BASIX_TOR_HOST must be basix-tor-proxy or a private IPv4 legacy value")
    if PORT < 1024 or PORT > 65535:
        raise RuntimeError("BASIX_PORT must be an unprivileged TCP port")


def canonical_client_id(value):
    """Return a canonical UUID v4 or reject the tool call."""
    if not isinstance(value, str):
        raise ValueError("client_id must be a canonical UUID v4")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError):
        raise ValueError("client_id must be a canonical UUID v4") from None
    if parsed.version != 4 or str(parsed) != value:
        raise ValueError("client_id must be a canonical UUID v4")
    return value


def _session_id(result):
    """Extract the upstream-generated identifier without constraining its payload."""
    candidate = result
    if isinstance(candidate, str):
        try:
            candidate = json.loads(candidate)
        except (TypeError, ValueError):
            return candidate
    if isinstance(candidate, dict):
        for key in ("session_id", "id"):
            if isinstance(candidate.get(key), str):
                return candidate[key]
    for key in ("session_id", "id"):
        value = getattr(candidate, key, None)
        if isinstance(value, str):
            return value
    raise RuntimeError("Scrapling did not return a session identifier")


def _listed_session_id(item):
    try:
        return _session_id(item)
    except RuntimeError:
        return None


def _contains_istor(value):
    """Return whether a response payload recursively reports Tor egress.

    :param value: Scrapling response or decoded payload.
    """
    if isinstance(value, dict):
        return value.get("IsTor") is True or any(_contains_istor(item) for item in value.values())
    if isinstance(value, (list, tuple)):
        return any(_contains_istor(item) for item in value)
    if isinstance(value, str):
        try:
            return _contains_istor(json.loads(value))
        except (TypeError, ValueError):
            return False
    json_method = getattr(value, "json", None)
    if callable(json_method):
        try:
            return _contains_istor(json_method())
        except (TypeError, ValueError):
            return False
    return _contains_istor(getattr(value, "text", None)) if value is not None else False


def _proxy_failure(exc):
    """Return whether an exception indicates a Tor proxy transport failure.

    :param exc: Exception raised by an upstream network operation.
    """
    if isinstance(exc, urllib.error.HTTPError) or getattr(exc, "status", None):
        return False
    text = f"{type(exc).__name__} {exc}".lower()
    return any(marker in text for marker in ("proxy", "socks", "tunnel"))


class TorMonitor:
    """Track the Tor alias and coordinate one bounded recovery operation."""

    def __init__(self, host=TOR_HOST, *, resolver=None, probe=None, sleeper=None,
                 clock=None, jitter=None, confirmer=None, owner=None):
        """Create a monitor.

        :param host: Stable Tor network alias to resolve.
        :param resolver: Callable resolving the alias to an IPv4 address.
        :param probe: Callable probing an address and port with a timeout.
        :param sleeper: Async callable used for recovery delays.
        :param clock: Monotonic clock callable.
        :param jitter: Callable returning a jitter multiplier for a delay.
        :param confirmer: Async callable confirming external Tor egress.
        :param owner: Optional callable proving that a resolved address belongs to Tor.
        """
        self.host = host
        self.resolver = resolver or socket.gethostbyname
        self.probe = probe or self._probe
        self.sleeper = sleeper or asyncio.sleep
        self.clock = clock or time.monotonic
        self.jitter = jitter or (lambda delay: random.uniform(delay * .8, delay * 1.2))
        self.confirmer = confirmer
        self.owner = owner
        self.address = None
        self.generation = 0
        self.valid = False
        self.checked_at = float("-inf")
        self._recovery_lock = asyncio.Lock()

    @staticmethod
    def _probe(address, port=9050, timeout=1.0):
        """Probe Tor TCP readiness.

        :param address: Resolved Tor IPv4 address.
        :param port: Tor SOCKS TCP port.
        :param timeout: Connection timeout in seconds.
        """
        with socket.create_connection((address, port), timeout=timeout):
            return True

    def check(self, *, force=False):
        """Resolve and probe the alias when its five-second sample is due.

        :param force: Ignore the sampling interval when true.
        """
        now = self.clock()
        if not force and now - self.checked_at < 5.0:
            return self.valid
        self.checked_at = now
        try:
            address = self.resolver(self.host)
            parsed = ipaddress.ip_address(address)
            if parsed.version != 4 or not parsed.is_private:
                raise OSError("Tor alias resolved outside the private internal network")
            if self.owner is not None and not self.owner(self.host, address):
                raise OSError("Tor alias ownership could not be verified")
            self.probe(address, 9050, 1.0)
        except (OSError, ValueError, socket.timeout):
            self.invalidate()
            return False
        if address != self.address or not self.valid:
            self.address = address
            self.generation += 1
        self.valid = True
        return True

    def invalidate(self):
        """Immediately invalidate the current Tor generation."""
        self.valid = False

    async def recover(self):
        """Run or share bounded local recovery and external confirmation."""
        async with self._recovery_lock:
            if self.valid and self.check():
                return True
            for delay in RECOVERY_DELAYS:
                if delay:
                    await self.sleeper(self.jitter(delay))
                if self.check(force=True):
                    confirmed = self.confirmer is None or await self.confirmer()
                    if confirmed:
                        return True
                    self.invalidate()
                    return False
            return False

    async def execute(self, operation, *, retry=True):
        """Execute an operation with at most one proxy-failure retry.

        :param operation: Zero-argument async callable for the network operation.
        :param retry: Whether a single recovery retry is permitted.
        """
        try:
            return await operation()
        except Exception as exc:
            if not retry or not _proxy_failure(exc):
                raise
            self.invalidate()
            if not await self.recover():
                raise RuntimeError(TOR_UNAVAILABLE["error"]) from exc
            try:
                return await operation()
            except Exception as retry_exc:
                if _proxy_failure(retry_exc):
                    self.invalidate()
                    raise RuntimeError(TOR_UNAVAILABLE["error"]) from retry_exc
                raise


class ClientPolicy:
    """Own in-memory session capabilities and serialize lifecycle changes."""

    def __init__(self, server, monitor=None):
        """Create client isolation state.

        :param server: Upstream Scrapling MCP server.
        :param monitor: Tor monitor shared by all wrapped calls.
        """
        self.server = server
        self.monitor = monitor or TorMonitor()
        self.owners = {}
        self.session_locks = {}
        self.session_state = {}
        self.lifecycle_lock = asyncio.Lock()

    def _signature(self, method, *, hide_session=False):
        signature = inspect.signature(method)
        hidden = set(NETWORK_OVERRIDES)
        if hide_session:
            hidden.add("session_id")
        parameters = [p for p in signature.parameters.values() if p.name not in hidden]
        parameters.append(inspect.Parameter(
            "client_id", inspect.Parameter.KEYWORD_ONLY, annotation=str
        ))
        return signature.replace(parameters=parameters)

    @staticmethod
    def _description(method, *, alias_guidance=None):
        original = inspect.getdoc(method) or ""
        parts = [CLIENT_ID_GUIDANCE, CLIENT_ID_PARAMETER]
        if alias_guidance:
            parts.append(alias_guidance)
        parts.append(original)
        return "\n\n".join(parts).strip()

    def network_tool(self, method, *, browser=False, session_aware=False, forced=None):
        forced = forced or {}
        signature = inspect.signature(method)
        hidden = NETWORK_OVERRIDES.intersection(signature.parameters)

        @functools.wraps(method)
        async def guarded(*args, client_id, **kwargs):
            canonical_client_id(client_id)
            self.monitor.check()
            bound = signature.bind_partial(*args, **kwargs)
            session_id = bound.arguments.get("session_id") if session_aware else None
            lock = None
            if session_id:
                if self.owners.get(session_id) != client_id:
                    return SESSION_UNAVAILABLE.copy()
                lock = self.session_locks[session_id]
            for name in hidden:
                bound.arguments.pop(name, None)
            bound.arguments.update(forced)
            if not session_id:
                bound.arguments["proxy"] = BROWSER_PROXY if browser else HTTP_PROXY
            async def invoke():
                return await method(*bound.args, **bound.kwargs)
            if lock:
                async with lock:
                    state = self.session_state[session_id]
                    bound.arguments["session_id"] = state["upstream_id"]
                    try:
                        return await invoke()
                    except Exception as exc:
                        if not _proxy_failure(exc):
                            raise
                        self.monitor.invalidate()
                        if not await self.monitor.recover():
                            raise RuntimeError(TOR_UNAVAILABLE["error"]) from exc
                        try:
                            await self._recreate_session(session_id)
                        except Exception as recreate_exc:
                            if _proxy_failure(recreate_exc):
                                self.monitor.invalidate()
                                raise RuntimeError(TOR_UNAVAILABLE["error"]) from recreate_exc
                            raise
                        bound.arguments["session_id"] = state["upstream_id"]
                        try:
                            return await invoke()
                        except Exception as retry_exc:
                            if _proxy_failure(retry_exc):
                                self.monitor.invalidate()
                                raise RuntimeError(TOR_UNAVAILABLE["error"]) from retry_exc
                            raise
            return await self.monitor.execute(invoke)

        guarded.__signature__ = self._signature(method)
        alias_guidance = BULK_FETCH_GUIDANCE if method.__name__ in {
            "bulk_fetch", "bulk_stealthy_fetch"
        } else None
        guarded.__doc__ = self._description(method, alias_guidance=alias_guidance)
        return guarded

    def singular_network_tool(self, method, bulk_method):
        """Adapt Scrapling's singular aliases to the policy-wrapped bulk tool."""
        bulk_guarded = bulk_method

        @functools.wraps(method)
        async def guarded(*args, client_id, **kwargs):
            canonical_client_id(client_id)
            bound = inspect.signature(method).bind(*args, **kwargs)
            url = bound.arguments.pop("url")
            result = await bulk_guarded(urls=[url], client_id=client_id, **bound.arguments)
            return result[0] if isinstance(result, (list, tuple)) else result

        guarded.__signature__ = self._signature(method)
        guarded.__doc__ = self._description(method, alias_guidance=SINGULAR_FETCH_GUIDANCE)
        return guarded

    def open_session(self, method, *, kind, forced=None):
        forced = forced or {}
        signature = inspect.signature(method)

        @functools.wraps(method)
        async def guarded(*args, client_id, **kwargs):
            canonical_client_id(client_id)
            bound = signature.bind_partial(*args, **kwargs)
            # The upstream accepts an optional caller-selected session_id, but
            # the policy owns session identity and must discard it whether the
            # caller supplied it positionally or by keyword.
            bound.arguments.pop("session_id", None)
            for name in NETWORK_OVERRIDES:
                bound.arguments.pop(name, None)
            bound.arguments.update(forced)
            bound.arguments["proxy"] = BROWSER_PROXY if kind == "browser" else HTTP_PROXY
            async with self.lifecycle_lock:
                result = await method(*bound.args, **bound.kwargs)
                session_id = _session_id(result)
                if session_id in self.owners:
                    raise RuntimeError("Scrapling returned a duplicate session identifier")
                self.owners[session_id] = client_id
                self.session_locks[session_id] = asyncio.Lock()
                self.session_state[session_id] = {
                    "upstream_id": session_id,
                    "public_result": result,
                    "generation": self.monitor.generation,
                    "method": method,
                    "kind": kind,
                    "args": bound.args,
                    "kwargs": dict(bound.kwargs),
                }
                return result

        guarded.__signature__ = self._signature(method, hide_session=True)
        guarded.__doc__ = self._description(method)
        return guarded

    def list_sessions(self, method):
        @functools.wraps(method)
        async def guarded(*args, client_id, **kwargs):
            canonical_client_id(client_id)
            async with self.lifecycle_lock:
                result = await method(*args, **kwargs)
                if not isinstance(result, list):
                    raise RuntimeError("Scrapling returned an unsupported session list")
                upstream_ids = {_listed_session_id(item) for item in result}
                return [
                    state["public_result"] for public_id, state in self.session_state.items()
                    if self.owners.get(public_id) == client_id
                    and state["upstream_id"] in upstream_ids
                ]

        guarded.__signature__ = self._signature(method)
        guarded.__doc__ = self._description(method)
        return guarded

    def close_session(self, method):
        @functools.wraps(method)
        async def guarded(*args, client_id, **kwargs):
            canonical_client_id(client_id)
            session_id = kwargs.get("session_id")
            if session_id is None and args:
                session_id = args[0]
            async with self.lifecycle_lock:
                if self.owners.get(session_id) != client_id:
                    return SESSION_UNAVAILABLE.copy()
                lock = self.session_locks[session_id]
                async with lock:
                    upstream_id = self.session_state[session_id]["upstream_id"]
                    if "session_id" in kwargs:
                        kwargs["session_id"] = upstream_id
                        call_args = args
                    else:
                        call_args = (upstream_id, *args[1:])
                    result = await method(*call_args, **kwargs)
                self.owners.pop(session_id, None)
                self.session_locks.pop(session_id, None)
                self.session_state.pop(session_id, None)
                return result

        guarded.__signature__ = self._signature(method)
        guarded.__doc__ = self._description(method)
        return guarded

    async def _recreate_session(self, public_id):
        """Atomically replace one upstream browser session.

        :param public_id: Stable client-visible session identifier.
        """
        state = self.session_state[public_id]
        result = await state["method"](*state["args"], **state["kwargs"])
        upstream_id = _session_id(result)
        state["upstream_id"] = upstream_id
        state["generation"] = self.monitor.generation


def assert_upstream_tools(server):
    actual = {tool.name for tool in asyncio.run(server._build_server("127.0.0.1", PORT).list_tools())}
    if actual != EXPECTED_TOOLS:
        raise RuntimeError(f"Unsupported Scrapling MCP tool set: {sorted(actual)}")
    for name in EXPECTED_TOOLS:
        unknown = {
            parameter for parameter in inspect.signature(getattr(server, name)).parameters
            if SUSPICIOUS_NETWORK_NAME.search(parameter) and parameter not in NETWORK_OVERRIDES
        }
        if unknown:
            raise RuntimeError(f"Unreviewed network parameters on {name}: {sorted(unknown)}")
    required = {
        "open_session": {"session_id", "proxy", "cdp_url", "real_chrome", "executable_path", "additional_args", "block_webrtc"},
        "open_request_session": {"session_id", "proxy"},
        "make_request": {"url", "proxy", "proxy_auth", "auth", "http3"},
        "bulk_get": {"urls", "proxy", "proxy_auth", "auth", "http3"},
        "session_make_request": {"url", "session_id", "auth", "http3"},
        "fetch": {"url", "proxy", "cdp_url", "real_chrome", "executable_path"},
        "bulk_fetch": {"urls", "proxy", "cdp_url", "real_chrome", "executable_path"},
        "session_fetch": {"url", "session_id"},
        "stealthy_fetch": {"url", "proxy", "cdp_url", "real_chrome", "executable_path", "additional_args", "block_webrtc"},
        "bulk_stealthy_fetch": {"urls", "proxy", "cdp_url", "real_chrome", "executable_path", "additional_args", "block_webrtc"},
        "screenshot": {"url", "session_id"},
        "close_session": {"session_id"},
    }
    for name, parameters in required.items():
        missing = parameters.difference(inspect.signature(getattr(server, name)).parameters)
        if missing:
            raise RuntimeError(f"Unsupported Scrapling {name} signature: missing {sorted(missing)}")
    for singular, bulk in (("fetch", "bulk_fetch"), ("stealthy_fetch", "bulk_stealthy_fetch")):
        if "url" not in inspect.signature(getattr(server, singular)).parameters:
            raise RuntimeError(f"Unsupported Scrapling {singular} signature: missing url")
        if "urls" not in inspect.signature(getattr(server, bulk)).parameters:
            raise RuntimeError(f"Unsupported Scrapling {bulk} signature: missing urls")


def configure_server(server, monitor=None):
    """Install policy wrappers.

    :param server: Upstream Scrapling MCP server.
    :param monitor: Optional testable Tor monitor.
    :return: Client policy owner.
    """
    upstream_request = server.make_request
    if monitor is None:
        async def confirm_tor():
            result = await upstream_request(
                "https://check.torproject.org/api/ip", proxy=HTTP_PROXY, http3=False
            )
            return _contains_istor(result)
        monitor = TorMonitor(confirmer=confirm_tor)
    policy = ClientPolicy(server, monitor)
    server.make_request = policy.network_tool(server.make_request, forced={"http3": False})
    server.bulk_get = policy.network_tool(server.bulk_get, forced={"http3": False})
    server.open_session = policy.open_session(
        server.open_session, kind="browser", forced={"block_webrtc": True}
    )
    server.open_request_session = policy.open_session(
        server.open_request_session, kind="request"
    )
    server.list_sessions = policy.list_sessions(server.list_sessions)
    server.close_session = policy.close_session(server.close_session)
    for name in ("bulk_fetch", "bulk_stealthy_fetch"):
        method = getattr(server, name)
        setattr(
            server,
            name,
            policy.network_tool(
                method,
                browser=True,
                forced={"block_webrtc": True} if "stealthy" in name else None,
            ),
        )
    for name, bulk_name in (("fetch", "bulk_fetch"), ("stealthy_fetch", "bulk_stealthy_fetch")):
        setattr(
            server,
            name,
            policy.singular_network_tool(getattr(server, name), getattr(server, bulk_name)),
        )
    server.session_make_request = policy.network_tool(
        server.session_make_request, session_aware=True, forced={"http3": False}
    )
    for name in ("session_fetch", "screenshot"):
        method = getattr(server, name)
        setattr(server, name, policy.network_tool(method, browser=True, session_aware=True))
    return policy


def main():
    validate_configuration()
    browser_base.DEFAULT_ARGS = tuple(dict.fromkeys((*browser_base.DEFAULT_ARGS, *CHROMIUM_FLAGS)))
    browser_base.STEALTH_ARGS = tuple(dict.fromkeys((*browser_base.STEALTH_ARGS, *CHROMIUM_FLAGS)))
    server = ScraplingMCPServer()
    assert_upstream_tools(server)
    configure_server(server)
    server.serve(
        http=True,
        host="0.0.0.0",
        port=PORT,
        allowed_hosts=[f"127.0.0.1:{PORT}", f"localhost:{PORT}"],
        allow_unauthenticated=True,
    )


if __name__ == "__main__":
    main()

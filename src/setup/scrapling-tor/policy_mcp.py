"""Fail-closed, multi-client Scrapling MCP policy for the Basix Tor service."""
import asyncio
import functools
import inspect
import ipaddress
import json
import os
import re
import uuid

from scrapling.core.ai import ScraplingMCPServer
from scrapling.engines._browsers import _base as browser_base

EXPECTED_TOOLS = {
    "open_session", "close_session", "list_sessions", "get", "bulk_get",
    "fetch", "bulk_fetch", "stealthy_fetch", "bulk_stealthy_fetch", "screenshot",
}
NETWORK_OVERRIDES = {
    "proxy", "proxy_auth", "cdp_url", "real_chrome", "executable_path",
    "additional_args", "block_webrtc", "dns_over_https", "http3", "extra_flags",
}
SESSION_TOOLS = {
    "close_session", "fetch", "bulk_fetch", "stealthy_fetch",
    "bulk_stealthy_fetch", "screenshot",
}
TOR_IP = os.environ["BASIX_TOR_IP"]
PORT = int(os.environ.get("BASIX_PORT", "8002"))
HTTP_PROXY = f"socks5h://{TOR_IP}:9050"
BROWSER_PROXY = f"socks5://{TOR_IP}:9050"
CHROMIUM_FLAGS = (
    "--disable-quic",
    "--disable-features=WebRtcHideLocalIpsWithMdns,UseDnsHttpsSvcbAlpn",
    "--webrtc-ip-handling-policy=disable_non_proxied_udp",
    "--force-webrtc-ip-handling-policy",
)
SUSPICIOUS_NETWORK_NAME = re.compile(r"proxy|cdp|chrome|execut|argument|webrtc|dns|http3|quic", re.I)
SESSION_UNAVAILABLE = {"error": "session not available"}


def validate_configuration():
    """Reject unsafe environment configuration before opening the listener."""
    address = ipaddress.ip_address(TOR_IP)
    if address.version != 4 or not address.is_private:
        raise RuntimeError("BASIX_TOR_IP must be a private IPv4 address")
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


class ClientPolicy:
    """Own in-memory session capabilities and serialize lifecycle changes."""

    def __init__(self, server):
        self.server = server
        self.owners = {}
        self.session_locks = {}
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

    def network_tool(self, method, *, browser=False, session_aware=False, forced=None):
        forced = forced or {}
        signature = inspect.signature(method)
        hidden = NETWORK_OVERRIDES.intersection(signature.parameters)

        @functools.wraps(method)
        async def guarded(*args, client_id, **kwargs):
            canonical_client_id(client_id)
            session_id = kwargs.get("session_id") if session_aware else None
            lock = None
            if session_id:
                if self.owners.get(session_id) != client_id:
                    return SESSION_UNAVAILABLE.copy()
                lock = self.session_locks[session_id]
            for name in hidden:
                kwargs.pop(name, None)
            if not session_id:
                kwargs.update(forced)
                kwargs["proxy"] = BROWSER_PROXY if browser else HTTP_PROXY
            if lock:
                async with lock:
                    return await method(*args, **kwargs)
            return await method(*args, **kwargs)

        guarded.__signature__ = self._signature(method)
        return guarded

    def open_session(self, method):
        @functools.wraps(method)
        async def guarded(*args, client_id, **kwargs):
            canonical_client_id(client_id)
            kwargs.pop("session_id", None)
            for name in NETWORK_OVERRIDES:
                kwargs.pop(name, None)
            kwargs.update(proxy=BROWSER_PROXY, block_webrtc=True)
            async with self.lifecycle_lock:
                result = await method(*args, **kwargs)
                session_id = _session_id(result)
                if session_id in self.owners:
                    raise RuntimeError("Scrapling returned a duplicate session identifier")
                self.owners[session_id] = client_id
                self.session_locks[session_id] = asyncio.Lock()
                return result

        guarded.__signature__ = self._signature(method, hide_session=True)
        return guarded

    def list_sessions(self, method):
        @functools.wraps(method)
        async def guarded(*args, client_id, **kwargs):
            canonical_client_id(client_id)
            async with self.lifecycle_lock:
                result = await method(*args, **kwargs)
                if not isinstance(result, list):
                    raise RuntimeError("Scrapling returned an unsupported session list")
                return [item for item in result if self.owners.get(_listed_session_id(item)) == client_id]

        guarded.__signature__ = self._signature(method)
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
                    result = await method(*args, **kwargs)
                self.owners.pop(session_id, None)
                self.session_locks.pop(session_id, None)
                return result

        guarded.__signature__ = self._signature(method)
        return guarded


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


def configure_server(server):
    """Install policy wrappers and return the session owner for testing."""
    policy = ClientPolicy(server)
    server.get = policy.network_tool(server.get, forced={"http3": False})
    server.bulk_get = policy.network_tool(server.bulk_get, forced={"http3": False})
    server.open_session = policy.open_session(server.open_session)
    server.list_sessions = policy.list_sessions(server.list_sessions)
    server.close_session = policy.close_session(server.close_session)
    for name in ("fetch", "bulk_fetch", "stealthy_fetch", "bulk_stealthy_fetch", "screenshot"):
        method = getattr(server, name)
        forced = {"block_webrtc": True} if "stealthy" in name else None
        setattr(server, name, policy.network_tool(method, browser=True, session_aware=True, forced=forced))
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
    )


if __name__ == "__main__":
    main()

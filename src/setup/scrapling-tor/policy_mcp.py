"""Fail-closed Scrapling MCP policy for the Basix managed Tor sidecar."""
import asyncio
import functools
import inspect
import os
import re

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
TOR_IP = os.environ["BASIX_TOR_IP"]
HTTP_PROXY = f"socks5h://{TOR_IP}:9050"
BROWSER_PROXY = f"socks5://{TOR_IP}:9050"
CHROMIUM_FLAGS = (
    "--disable-quic",
    "--disable-features=WebRtcHideLocalIpsWithMdns,UseDnsHttpsSvcbAlpn",
    "--webrtc-ip-handling-policy=disable_non_proxied_udp",
    "--force-webrtc-ip-handling-policy",
)
SUSPICIOUS_NETWORK_NAME = re.compile(r"proxy|cdp|chrome|execut|argument|webrtc|dns|http3|quic", re.I)


def enforce(method, *, browser=False, session_aware=False, forced=None):
    """Remove caller network controls and enforce Tor for one-shot calls."""
    forced = forced or {}
    signature = inspect.signature(method)
    hidden = NETWORK_OVERRIDES.intersection(signature.parameters)
    parameters = [p for p in signature.parameters.values() if p.name not in hidden]

    @functools.wraps(method)
    async def guarded(*args, **kwargs):
        uses_session = session_aware and bool(kwargs.get("session_id"))
        for name in hidden:
            kwargs.pop(name, None)
        if not uses_session:
            kwargs.update(forced)
            kwargs["proxy"] = BROWSER_PROXY if browser else HTTP_PROXY
        return await method(*args, **kwargs)

    guarded.__signature__ = signature.replace(parameters=parameters)
    return guarded


def assert_upstream_tools(server):
    actual = {tool.name for tool in asyncio.run(server._build_server("127.0.0.1", 8000).list_tools())}
    if actual != EXPECTED_TOOLS:
        raise RuntimeError(f"Unsupported Scrapling MCP tool set: {sorted(actual)}")

    for name in EXPECTED_TOOLS:
        method = getattr(server, name)
        unknown = {
            parameter for parameter in inspect.signature(method).parameters
            if SUSPICIOUS_NETWORK_NAME.search(parameter) and parameter not in NETWORK_OVERRIDES
        }
        if unknown:
            raise RuntimeError(f"Unreviewed network parameters on {name}: {sorted(unknown)}")


def main():
    # These tuples feed Chromium's immutable launch argument set. Caller-facing
    # override parameters are removed below, so these flags cannot be displaced.
    browser_base.DEFAULT_ARGS = tuple(dict.fromkeys((*browser_base.DEFAULT_ARGS, *CHROMIUM_FLAGS)))
    browser_base.STEALTH_ARGS = tuple(dict.fromkeys((*browser_base.STEALTH_ARGS, *CHROMIUM_FLAGS)))

    server = ScraplingMCPServer()
    assert_upstream_tools(server)
    server.get = enforce(server.get, forced={"http3": False})
    server.bulk_get = enforce(server.bulk_get, forced={"http3": False})
    server.open_session = enforce(server.open_session, browser=True, forced={"block_webrtc": True})
    server.fetch = enforce(server.fetch, browser=True, session_aware=True)
    server.bulk_fetch = enforce(server.bulk_fetch, browser=True, session_aware=True)
    server.stealthy_fetch = enforce(
        server.stealthy_fetch, browser=True, session_aware=True, forced={"block_webrtc": True}
    )
    server.bulk_stealthy_fetch = enforce(
        server.bulk_stealthy_fetch, browser=True, session_aware=True, forced={"block_webrtc": True}
    )
    server.serve(http=False, host="127.0.0.1", port=8000)


if __name__ == "__main__":
    main()

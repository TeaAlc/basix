#!/usr/bin/env python3
"""Container-local child supervision; no website or external canary controls recovery."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
import urllib.request


def log(message: str) -> None:
    """Write a diagnostic; message is the non-secret event description."""
    print(f"basix-supervisor: {message}", file=sys.stderr, flush=True)


def receive(sock: socket.socket, size: int) -> bytes:
    """Read exactly size bytes from sock, rejecting a closed connection."""
    result = b""
    while len(result) < size:
        part = sock.recv(size - len(result))
        if not part:
            raise RuntimeError("SOCKS connection closed during negotiation")
        result += part
    return result


def tor_probe() -> int:
    """Check live local SOCKS/control; return 2 for external circuit unavailability."""
    with socket.create_connection(("127.0.0.1", 9050), 2) as sock:
        sock.sendall(b"\x05\x01\x00")
        if receive(sock, 2) != b"\x05\x00":
            raise RuntimeError("SOCKS5 negotiation failed")
    cookie = Path("/var/lib/tor/control_auth_cookie").read_bytes().hex()
    with socket.create_connection(("127.0.0.1", 9051), 2) as sock:
        stream = sock.makefile("rb")
        sock.sendall(f"AUTHENTICATE {cookie}\r\n".encode())
        if stream.readline(4096).strip() != b"250 OK":
            raise RuntimeError("Tor control authentication failed")
        sock.sendall(b"GETINFO status/bootstrap-phase status/circuit-established\r\n")
        lines = []
        for _ in range(16):
            line = stream.readline(4096).strip()
            lines.append(line)
            if line == b"250 OK":
                break
            if not line or not line.startswith(b"250-"):
                raise RuntimeError("Tor control GETINFO failed")
        else:
            raise RuntimeError("Tor control response exceeded bounds")
    ready = any(b"PROGRESS=100" in line for line in lines)
    circuit = b"250-status/circuit-established=1" in lines
    if not ready or not circuit:
        log(f"Tor local services responsive; bootstrap_complete={ready} circuit_established={circuit}; awaiting network without restart")
        return 2
    return 0


def mcp_probe() -> int:
    """Check a fresh local MCP initialize/ping exchange without invoking a website."""
    port = int(os.environ.get("BASIX_PORT", "8002"))
    endpoint = f"http://127.0.0.1:{port}/mcp"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    payloads = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "basix-supervisor", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "ping"},
    ]
    try:
        for payload in payloads:
            request = urllib.request.Request(endpoint, json.dumps(payload).encode(), headers)
            with opener.open(request, timeout=2) as response:
                session = response.headers.get("Mcp-Session-Id")
                if session:
                    headers["Mcp-Session-Id"] = session
                body = response.read(65537).decode()
            if len(body) > 65536:
                raise RuntimeError("MCP probe response exceeded bounds")
            if "id" in payload:
                events = [line[5:].strip() for line in body.splitlines() if line.startswith("data:")]
                value = json.loads(events[-1] if events else body)
                if value.get("jsonrpc") != "2.0" or value.get("id") != payload["id"] or not isinstance(value.get("result"), dict) or "error" in value:
                    raise RuntimeError("MCP probe returned an invalid protocol result")
                if payload["method"] == "initialize":
                    result = value["result"]
                    if not isinstance(result.get("protocolVersion"), str) or not isinstance(result.get("capabilities"), dict) or not isinstance(result.get("serverInfo"), dict):
                        raise RuntimeError("MCP probe returned an invalid initialization result")
    finally:
        if "Mcp-Session-Id" in headers:
            try:
                with opener.open(urllib.request.Request(endpoint, headers=headers, method="DELETE"), timeout=1):
                    pass
            except OSError:
                pass
    return 0


def reap(child: subprocess.Popen) -> None:
    """Reap adopted descendants and update child when its process exits."""
    while True:
        try:
            pid, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            return
        if pid == child.pid:
            child.returncode = os.waitstatus_to_exitcode(status)


def stop(child: subprocess.Popen, grace: float, signum: int = signal.SIGTERM) -> None:
    """Stop child's process group, allowing grace seconds after forwarding signum."""
    try:
        os.killpg(child.pid, signum)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        reap(child)
        # Descendants may remain after the primary child exits.
        try:
            os.killpg(child.pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.05)
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass
    reap(child)


def supervise(args: argparse.Namespace) -> int:
    """Supervise the child and readiness probe configured by args."""
    shutdown = 0

    def interrupted(signum: int, frame: object) -> None:
        """Remember signum for forwarding; frame is the ignored Python signal frame."""
        nonlocal shutdown
        shutdown = signum

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, interrupted)
    command = args.command or (["tor", "-f", "/etc/tor/torrc"] if args.kind == "tor" else [sys.executable, "/opt/basix/policy_mcp.py"])
    probe_command = args.probe_command or [sys.executable, str(Path(__file__).resolve()), "--probe", args.kind]
    restarts = []
    child = None
    try:
        while not shutdown:
            child = subprocess.Popen(command, start_new_session=True)
            log(f"started {args.kind} child pid={child.pid}")
            started = time.monotonic()
            next_probe = started
            failures = 0
            while not shutdown:
                reap(child)
                if child.returncode is not None:
                    log(f"{args.kind} child exited status={child.returncode}; exiting for container restart policy")
                    return 1
                now = time.monotonic()
                if now >= next_probe:
                    try:
                        result = subprocess.run(probe_command, timeout=args.probe_timeout, check=False)
                        healthy = result.returncode == 0 or (args.kind == "tor" and result.returncode == 2)
                        detail = f"status={result.returncode}"
                    except subprocess.TimeoutExpired:
                        healthy, detail = False, "timed out"
                    if healthy:
                        if failures:
                            log(f"{args.kind} readiness recovered before restart")
                        failures = 0
                    elif now - started >= args.start_grace:
                        failures += 1
                        log(f"{args.kind} local readiness failure {failures}/{args.failures}: {detail}")
                    next_probe = time.monotonic() + args.interval
                    if failures >= args.failures:
                        break
                time.sleep(0.1)
            if shutdown:
                break
            stop(child, args.stop_grace)
            child = None
            now = time.monotonic()
            restarts = [value for value in restarts if now - value < args.restart_window]
            if len(restarts) >= args.max_restarts:
                log(f"{args.kind} restart budget exhausted; exiting for container restart policy")
                return 1
            restarts.append(now)
            log(f"restarting {args.kind} after cooldown={args.cooldown}s")
            deadline = now + args.cooldown
            while not shutdown and time.monotonic() < deadline:
                time.sleep(0.1)
        return 0
    finally:
        if child is not None:
            stop(child, args.stop_grace, shutdown or signal.SIGTERM)
        log(f"{args.kind} supervisor stopped signal={shutdown}")


def main() -> int:
    """Parse supervisor or one-shot probe arguments and run the requested mode."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", choices=("tor", "mcp"))
    parser.add_argument("kind", nargs="?", choices=("tor", "mcp"))
    parser.add_argument("--interval", type=float, default=15)
    parser.add_argument("--probe-timeout", type=float, default=5)
    parser.add_argument("--start-grace", type=float, default=120)
    parser.add_argument("--failures", type=int, default=3)
    parser.add_argument("--cooldown", type=float, default=30)
    parser.add_argument("--max-restarts", type=int, default=3)
    parser.add_argument("--restart-window", type=float, default=600)
    parser.add_argument("--stop-grace", type=float, default=3)
    parser.add_argument("--probe-command", nargs="+")
    parser.add_argument("--command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.probe:
        try:
            return tor_probe() if args.probe == "tor" else mcp_probe()
        except Exception as error:
            log(f"{args.probe} local probe failed: {type(error).__name__}: {error}")
            return 1
    if not args.kind:
        parser.error("kind or --probe is required")
    if any(getattr(args, key) <= 0 for key in ("interval", "probe_timeout", "failures", "max_restarts", "restart_window", "stop_grace")) or args.start_grace < 0 or args.cooldown < 0:
        parser.error("timings and limits must be positive (grace/cooldown may be zero)")
    return supervise(args)


if __name__ == "__main__":
    raise SystemExit(main())

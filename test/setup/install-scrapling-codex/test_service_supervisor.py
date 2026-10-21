#!/usr/bin/env python3
"""Deterministic child lifecycle and local-protocol supervision checks."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch, MagicMock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SOURCE = Path(__file__).resolve().parents[3] / "src/setup/scrapling-tor/service_supervisor.py"
spec = importlib.util.spec_from_file_location("service_supervisor", SOURCE)
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)


class SupervisorTests(unittest.TestCase):
    """Exercise real subprocess recovery without a runtime or external network."""

    def setUp(self):
        """Create self's isolated child and probe scripts."""
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.child = self.root / "child.py"
        self.probe = self.root / "probe.py"
        self.child.write_text('''import os, pathlib, signal, time
root = pathlib.Path(__file__).parent
with (root / "starts").open("a") as output: output.write(str(os.getpid()) + "\\n")
def stop(signum, frame):
    """Record signum and exit; frame is the unused signal frame."""
    (root / "signal").write_text(str(signum))
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
while True: time.sleep(0.05)
''')
        self.probe.write_text("raise SystemExit(0)\n")

    def command(self, *extra):
        """Build self's supervisor command with extra CLI overrides."""
        return [sys.executable, str(SOURCE), "mcp", "--interval", "0.05", "--start-grace", "0",
                "--stop-grace", "0.2", "--probe-timeout", "0.15", "--cooldown", "0.05",
                "--failures", "2", "--max-restarts", "1", *extra,
                "--probe-command", sys.executable, str(self.probe),
                "--command", sys.executable, str(self.child)]

    def wait_for(self, predicate, timeout=5):
        """Wait up to timeout seconds for predicate within self's test."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail("timed out waiting for lifecycle evidence")

    def test_child_exit_exits_for_container_restart(self):
        """Assert self's unexpected child exit produces a failing container exit."""
        self.child.write_text("raise SystemExit(0)\n")
        result = subprocess.run(self.command(), capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn("child exited status=0", result.stderr)

    def test_hung_probe_recovers_then_exhausts_bounded_budget(self):
        """Assert self's hung probes restart a real child within a bounded budget."""
        self.probe.write_text("import time\ntime.sleep(10)\n")
        result = subprocess.run(self.command(), capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len((self.root / "starts").read_text().splitlines()), 2)
        self.assertIn("timed out", result.stderr)
        self.assertIn("restart budget exhausted", result.stderr)

    def test_transient_failure_and_startup_grace_do_not_restart(self):
        """Assert self's short readiness failure clears before the restart threshold."""
        self.probe.write_text('''from pathlib import Path
root = Path(__file__).parent
marker = root / "probes"
n = int(marker.read_text()) if marker.exists() else 0
marker.write_text(str(n+1))
raise SystemExit(1 if n < 2 else 0)
''')
        process = subprocess.Popen(self.command("--start-grace", "0.25"), stderr=subprocess.PIPE, text=True)
        try:
            self.wait_for(lambda: (self.root / "probes").exists() and int((self.root / "probes").read_text() or "0") >= 4)
            process.terminate()
            _, diagnostics = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0)
            self.assertNotIn("restarting", diagnostics)
            self.assertEqual(len((self.root / "starts").read_text().splitlines()), 1)
            self.assertEqual((self.root / "signal").read_text(), str(signal.SIGTERM))
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_consecutive_failures_reset_after_recovery(self):
        """Assert self's separated local failures never accumulate across successes."""
        self.probe.write_text('''from pathlib import Path
marker = Path(__file__).with_name("probes")
n = int(marker.read_text()) if marker.exists() else 0
marker.write_text(str(n+1))
raise SystemExit(1 if n % 2 == 0 else 0)
''')
        process = subprocess.Popen(self.command(), stderr=subprocess.PIPE, text=True)
        try:
            self.wait_for(lambda: (self.root / "probes").exists() and int((self.root / "probes").read_text() or "0") >= 6)
            process.terminate()
            _, diagnostics = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0)
            self.assertNotIn("restarting", diagnostics)
            self.assertIn("recovered before restart", diagnostics)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_missing_circuit_is_degraded_without_local_restart_failure(self):
        """Assert self's Tor probe distinguishes circuit absence from local failure."""
        socks = MagicMock()
        socks.recv.return_value = b"\x05\x00"
        control = MagicMock()
        control.makefile.return_value.readline.side_effect = [
            b"250 OK\r\n", b"250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=100\r\n",
            b"250-status/circuit-established=0\r\n", b"250 OK\r\n"]
        contexts = []
        for connection in (socks, control):
            context = MagicMock()
            context.__enter__.return_value = connection
            contexts.append(context)
        with patch.object(supervisor.socket, "create_connection", side_effect=contexts), patch.object(supervisor.Path, "read_bytes", return_value=b"cookie"):
            self.assertEqual(supervisor.tor_probe(), 2)

    def test_reaper_collects_primary_and_other_exited_children(self):
        """Assert self's reaper drains exited primary and adopted-child equivalents."""
        primary = subprocess.Popen([sys.executable, "-c", "raise SystemExit(9)"])
        other = subprocess.Popen([sys.executable, "-c", "raise SystemExit(0)"])
        try:
            self.wait_for(lambda: all(Path(f"/proc/{process.pid}/stat").read_text().split()[2] == "Z" for process in (primary, other)))
            supervisor.reap(primary)
            self.assertEqual(primary.returncode, 9)
            with self.assertRaises(ChildProcessError):
                os.waitpid(other.pid, os.WNOHANG)
            other.returncode = 0
        finally:
            for process in (primary, other):
                if process.poll() is None:
                    process.kill()
                process.wait()

    def test_signal_shutdown_kills_and_reaps_a_stopped_child(self):
        """Assert self's stopped child cannot prevent bounded signal shutdown."""
        process = subprocess.Popen(self.command(), stderr=subprocess.PIPE, text=True)
        try:
            self.wait_for(lambda: (self.root / "starts").exists())
            pid = int((self.root / "starts").read_text())
            os.kill(pid, signal.SIGSTOP)
            process.terminate()
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0)
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


class MCPHandler(BaseHTTPRequestHandler):
    """Serve the local protocol probe only, rejecting every unplanned method."""

    def log_message(self, format, *args):
        """Suppress self's HTTP logs; format and args are unused logging inputs."""

    def do_POST(self):
        """Reply to self's initialize/notification/ping protocol request."""
        value = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.methods.append(value["method"])
        assert value["method"] in {"initialize", "notifications/initialized", "ping"}
        result = {"protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": {"name": "test", "version": "1"}} if value["method"] == "initialize" else {}
        body = json.dumps({"jsonrpc": "2.0", "id": value.get("id"), "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class ProtocolTests(unittest.TestCase):
    """Verify current readiness without invoking external tools or websites."""

    def test_mcp_probe_uses_only_local_protocol_with_proxies_disabled(self):
        """Check self's live loopback fixture despite hostile ambient HTTP proxies."""
        server = ThreadingHTTPServer(("127.0.0.1", 0), MCPHandler)
        server.methods = []
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with patch.dict(os.environ, {"BASIX_PORT": str(server.server_port), "HTTP_PROXY": "http://127.0.0.1:1", "http_proxy": "http://127.0.0.1:1", "NO_PROXY": "", "no_proxy": ""}):
                self.assertEqual(supervisor.mcp_probe(), 0)
            self.assertEqual(server.methods, ["initialize", "notifications/initialized", "ping"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()

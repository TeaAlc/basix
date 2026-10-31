#!/usr/bin/env python3
"""Deterministic socket-pair protocol and artifact security acceptance."""
import asyncio
import gzip
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest
from unittest.mock import patch, MagicMock
import uuid

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("binary", ROOT / "src/setup/scrapling-tor/binary_acquisition.py")
binary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(binary)


class ProxyFixture:
    """Controlled SOCKS RESOLVE/CONNECT peer with raw HTTP responses."""

    def __init__(self, responses, resolved="93.184.216.34"):
        """Prepare fixture. :param responses: Raw HTTP responses. :param resolved: Remote DNS IP."""
        self.responses, self.resolved = list(responses), resolved
        self.commands, self.requests, self.threads, self.errors = [], [], [], []

    def connect(self, address, timeout):
        """Provide isolated socket pair. :param address: Managed proxy only. :param timeout: Socket timeout."""
        if address not in (("basix-tor-proxy", 9050), ("basix-tor-proxy", 9052)):
            raise AssertionError("direct connection attempted")
        client, server = socket.socketpair()
        client.settimeout(timeout)
        def serve():
            """Serve one bounded protocol conversation."""
            try:
                self._serve(server)
            except Exception as exc:
                self.errors.append(exc)
            finally:
                server.close()
        thread = threading.Thread(target=serve)
        self.threads.append(thread)
        thread.start()
        return client

    def _serve(self, server):
        """Handle protocol exactly. :param server: Socket peer."""
        self_test = binary.receive(server, 3)
        assert self_test == b"\x05\x01\x00"
        server.sendall(b"\x05\x00")
        version, command, reserved, kind = binary.receive(server, 4)
        assert version == 5 and reserved == 0
        count = binary.receive(server, 1)[0] if kind == 3 else 4 if kind == 1 else 16
        target = binary.receive(server, count)
        port = int.from_bytes(binary.receive(server, 2), "big")
        self.commands.append((command, kind, target, port))
        address = binary.ipaddress.ip_address(self.resolved)
        server.sendall(b"\x05\x00\x00" + bytes([1 if address.version == 4 else 4]) + address.packed + b"\x00\x00")
        if command == 0xF0:
            return
        if self.responses and self.responses[0] is None:
            return
        request = b""
        while not request.endswith(b"\r\n\r\n"):
            request += binary.receive(server, 1)
        self.requests.append(request)
        server.sendall(self.responses.pop(0))

    def finish(self):
        """Join every started fixture thread."""
        for thread in self.threads:
            thread.join(3)
            assert not thread.is_alive()
        if self.errors:
            raise self.errors[0]


def raw(body, headers=b""):
    """Construct HTTP fixture. :param body: Raw body. :param headers: Additional headers."""
    return b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(body)).encode() + b"\r\n" + headers + b"\r\n" + body


class TransportTests(unittest.TestCase):
    def acquire(self, responses, url="http://example.com/a?fake_secret=value", maximum=1000000, resolved="93.184.216.34"):
        """Exercise exact transport. :param responses: Raw HTTP fixtures. :param url: Initial URL. :param maximum: Byte limit. :param resolved: SOCKS resolution result."""
        fixture = ProxyFixture(responses, resolved)
        output = io.BytesIO()
        try:
            with patch.object(binary, "proxy_connect", fixture.connect):
                result = binary.TorTransport().download(url, output, maximum, time.monotonic() + 3, threading.Event())
            return result, output.getvalue(), fixture
        finally:
            fixture.finish()

    def test_managed_alias_resolution_has_killable_deadline(self):
        with patch.object(binary.subprocess, "run", side_effect=binary.subprocess.TimeoutExpired("resolver", .01)) as resolve, patch.object(binary.socket, "socket") as direct:
            with self.assertRaisesRegex(binary.AcquisitionError, "time_limit"):
                binary.proxy_connect(("basix-tor-proxy", 9050), .01)
            self.assertEqual(resolve.call_args.kwargs["timeout"], .01)
            direct.assert_not_called()
        peer = MagicMock()
        reply = binary.subprocess.CompletedProcess([], 0, b"10.89.0.2\n")
        with patch.object(binary.subprocess, "run", return_value=reply), patch.object(binary.socket, "socket", return_value=peer):
            self.assertIs(binary.proxy_connect(("basix-tor-proxy", 9052), 1), peer)
            peer.connect.assert_called_once_with(("10.89.0.2", 9052))
            self.assertLessEqual(peer.settimeout.call_args.args[0], 1)

    def test_exact_all_bytes_and_gzip_file(self):
        for body in (bytes(range(256)) * 1000, gzip.compress(bytes(range(256)))):
            result, output, fixture = self.acquire([raw(body, b"Content-Disposition: ../../evil\r\n")])
            self.assertEqual(output, body)
            self.assertEqual(result[:2], (len(body), hashlib.sha256(body).hexdigest()))
            self.assertEqual(result[2], ["http://example.com:80"])
            self.assertIn(b"Accept-Encoding: identity", fixture.requests[0])
            self.assertEqual(fixture.commands[0][0], 0xF0)
            self.assertEqual(fixture.commands[1][1:3], (1, socket.inet_aton("93.184.216.34")))

    def test_chunked_has_no_transfer_framing(self):
        response = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\n\x00\xffa\r\n2\r\nbc\r\n0\r\n\r\n"
        self.assertEqual(self.acquire([response])[1], b"\x00\xffabc")

    def test_encoding_truncation_and_limits(self):
        for response, maximum in ((raw(b"x", b"Content-Encoding: gzip\r\n"), 99), (b"HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\nx", 100), (raw(b"abcd"), 3), (b"HTTP/1.1 200 OK\r\n\r\n123456", 3)):
            with self.assertRaises(binary.AcquisitionError):
                self.acquire([response], maximum=maximum)

    def test_redirect_public_and_loop(self):
        redirect = b"HTTP/1.1 302 Found\r\nLocation: http://other.example/file?token=secret\r\nContent-Length: 0\r\n\r\n"
        result, output, fixture = self.acquire([redirect, raw(b"ok")])
        self.assertEqual(output, b"ok")
        self.assertEqual(len(result[2]), 2)
        self.assertNotIn("secret", str(result))
        with self.assertRaisesRegex(binary.AcquisitionError, "redirect_loop"):
            self.acquire([b"HTTP/1.1 302 Found\r\nLocation: /a?fake_secret=value\r\n\r\n"])
        for location in (b"http://127.0.0.1/", b"http://[::ffff:127.0.0.1]/"):
            with self.assertRaises(binary.AcquisitionError):
                self.acquire([b"HTTP/1.1 302 Found\r\nLocation: " + location + b"\r\n\r\n"])

    def test_private_remote_resolution_never_connects(self):
        fixture = ProxyFixture([], "127.0.0.1")
        try:
            with patch.object(binary, "proxy_connect", fixture.connect), self.assertRaises(binary.AcquisitionError):
                binary.TorTransport().response("http://example.com/", time.monotonic() + 3)
            self.assertEqual(len(fixture.commands), 1)
            self.assertEqual(fixture.requests, [])
        finally:
            fixture.finish()

    def test_tls_preserves_original_name_and_default_verification(self):
        fixture = ProxyFixture([raw(b"tls")])
        context = binary.ssl.create_default_context()
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, binary.ssl.CERT_REQUIRED)
        names = []
        class Context:
            def wrap_socket(self, sock, server_hostname):
                """Capture SNI. :param sock: Pinned socket. :param server_hostname: Original hostname."""
                names.append(server_hostname)
                return sock
        try:
            with patch.object(binary, "proxy_connect", fixture.connect), patch.object(binary.ssl, "create_default_context", return_value=Context()):
                output = io.BytesIO()
                binary.TorTransport().download("https://example.com/", output, 10, time.monotonic()+3, threading.Event())
            self.assertEqual(names, ["example.com"])
        finally:
            fixture.finish()

    def test_ambiguous_framing_and_redirect_cap(self):
        for response in (b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx", b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\nx"):
            with self.assertRaises(binary.AcquisitionError):
                self.acquire([response])
        redirects = [b"HTTP/1.1 302 Found\r\nLocation: /step"+str(i).encode()+b"\r\n\r\n" for i in range(6)]
        with self.assertRaisesRegex(binary.AcquisitionError, "redirect_limit"):
            self.acquire(redirects)

    def test_absolute_deadline_and_tor_failure_no_fallback(self):
        client, peer = socket.socketpair()
        try:
            reader = binary.DeadlineReader(client, time.monotonic() - 1)
            with self.assertRaisesRegex(binary.AcquisitionError, "time_limit"):
                reader.readinto(bytearray(1))
        finally:
            client.close()
            peer.close()
        with patch.object(binary, "proxy_connect", side_effect=ConnectionRefusedError()) as connect:
            with self.assertRaisesRegex(binary.AcquisitionError, "tor_transport_failed"):
                binary.TorTransport().response("http://example.com/", time.monotonic() + 1)
            self.assertEqual(connect.call_count, 1)
            self.assertEqual(connect.call_args.args[0], ("basix-tor-proxy", 9050))

    def test_url_rejections_before_socket(self):
        with self.assertRaises(binary.AcquisitionError):
            binary.target("http://example.com:0/")
        for url in ("file:///etc/passwd", "http://user:secret@example.com/", "http://127.1/", "http://2130706433/", "http://0x7f000001/", "http://127.0.0.1/", "http://169.254.169.254/", "http://[::1]/", "http://[::ffff:8.8.8.8]/", "http://example.com/%0d%0aHost:x", "http://example.com:9050/", "http://example.com\\@evil.com/"):
            with self.subTest(url=url), self.assertRaises(binary.AcquisitionError):
                binary.target(url)

    def test_slow_drip_still_hits_absolute_deadline(self):
        """A peer that never idles cannot extend the absolute reader budget."""
        client, peer = socket.socketpair()
        stop = threading.Event()
        def drip():
            """Send below any idle timeout until the test ends."""
            while not stop.wait(.005):
                try:
                    peer.sendall(b"x")
                except OSError:
                    return
        worker = threading.Thread(target=drip)
        worker.start()
        try:
            reader = binary.DeadlineReader(client, time.monotonic() + .05)
            started = time.monotonic()
            with self.assertRaises((binary.AcquisitionError, TimeoutError)):
                while True:
                    reader.readinto(bytearray(1))
            self.assertLess(time.monotonic() - started, .5)
        finally:
            stop.set()
            client.close()
            peer.close()
            worker.join(1)

    def test_failed_tls_and_https_downgrade(self):
        """Certificate failures and HTTPS-to-HTTP redirects fail before body output."""
        fixture = ProxyFixture([None])
        class Context:
            def wrap_socket(self, sock, server_hostname):
                """Reject certificate. :param sock: Pinned socket. :param server_hostname: Original SNI."""
                raise binary.ssl.SSLCertVerificationError("untrusted certificate")
        try:
            with patch.object(binary, "proxy_connect", fixture.connect), patch.object(binary.ssl, "create_default_context", return_value=Context()), self.assertRaisesRegex(binary.AcquisitionError, "tor_transport_failed"):
                binary.TorTransport().response("https://example.com/", time.monotonic() + 1)
        finally:
            fixture.finish()
        class PlainTLS:
            def wrap_socket(self, sock, server_hostname):
                """Keep fixture plain. :param sock: Fixture socket. :param server_hostname: SNI."""
                return sock
        with patch.object(binary.ssl, "create_default_context", return_value=PlainTLS()), self.assertRaisesRegex(binary.AcquisitionError, "https_downgrade"):
            self.acquire([b"HTTP/1.1 302 Found\r\nLocation: http://other.example/file\r\n\r\n"], url="https://example.com/")


class BodyTransport:
    def __init__(self, body=b"\x00\xffbinary", error=None):
        """Create bounded double. :param body: Exact bytes. :param error: Safe failure code."""
        self.body, self.error, self.calls = body, error, 0

    def download(self, url, output, maximum, deadline, cancelled):
        """Produce bytes. :param url: Sensitive input. :param output: Private sink. :param maximum: Byte cap. :param deadline: Deadline. :param cancelled: Event."""
        self.calls += 1
        output.write(self.body)
        if self.error:
            raise binary.AcquisitionError(self.error)
        return len(self.body), hashlib.sha256(self.body).hexdigest(), ["https://example.com:443"]


class JobTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        """Create isolated administrator state."""
        self.temp = tempfile.TemporaryDirectory()
        self.client, self.other = str(uuid.uuid4()), str(uuid.uuid4())
        self.transport = BodyTransport()
        async def ready():
            """Provide fixture Tor readiness."""
            return True
        self.manager = binary.AcquisitionManager(self.temp.name, self.transport, ready)

    async def test_periodic_orphan_cleanup_preserves_active_workers(self):
        """Transient deletion failures cannot accumulate unaccounted managed staging."""
        root = Path(self.temp.name)
        (root/"export").mkdir()
        for suffix in (".part", ".manifest"):
            (root/("a"*32 + suffix)).write_bytes(b"orphan")
        (root/"export"/("b"*32 + ".bin")).write_bytes(b"orphan")
        self.manager.orphan_exports.add("b"*32 + ".bin")
        active = "c"*32
        (root/(active + ".part")).write_bytes(b"active")
        self.manager.tasks[active] = None
        self.manager.cleanup()
        self.manager.tasks.clear()
        self.assertEqual(sorted(path.name for path in root.iterdir()), [active + ".part", "export"])
        self.assertEqual(list((root/"export").iterdir()), [])
        self.manager.cleanup()

    async def test_automatic_retention_retries_errors_without_new_calls(self):
        """The periodic task survives transient disk failures and runs without client calls."""
        from unittest.mock import AsyncMock
        with patch.object(binary.asyncio, "sleep", new=AsyncMock(side_effect=[None, None, asyncio.CancelledError()])), patch.object(self.manager, "cleanup", side_effect=[OSError("disk"), None]) as cleanup:
            with self.assertRaises(asyncio.CancelledError):
                await self.manager.maintain()
        self.assertEqual(cleanup.call_count, 2)

    async def test_repeated_retention_and_storage_errors_do_not_grow_state(self):
        """Expiry removes managed staging while repeated failed commits leave no partials."""
        for _ in range(12):
            job = await self.start()
            await self.manager.artifact_export(self.client, job["artifact_id"])
            self.manager.ttl = -1
            self.manager.cleanup()
            self.manager.ttl = 86400
            self.assertFalse(self.manager.jobs)
            self.assertFalse(self.manager.tasks)
            self.assertFalse(self.manager.events)
            self.assertEqual(list((Path(self.temp.name)/"export").iterdir()), [])
        for _ in range(4):
            with patch.object(binary.os, "fsync", side_effect=OSError("disk full")), self.assertRaises(OSError):
                await self.manager.download_start(self.client, "https://example.com/")
            self.assertFalse(list(Path(self.temp.name).glob("*.manifest")))
            self.assertFalse(self.manager.jobs)

    async def test_failed_export_commit_removes_unaccounted_copy(self):
        """Manifest failure keeps no leaked export and permits a bounded retry."""
        job = await self.start()
        with patch.object(self.manager, "persist", side_effect=OSError("disk full")), self.assertRaises(OSError):
            await self.manager.artifact_export(self.client, job["artifact_id"])
        self.assertNotIn("export_name", self.manager.jobs[job["job_id"]])
        self.assertEqual(list((Path(self.temp.name)/"export").iterdir()), [])
        await self.manager.artifact_export(self.client, job["artifact_id"])

    async def test_storage_reservation_includes_every_active_worker(self):
        """Originals and exports reserve space for all active jobs, including a new one."""
        self.manager.jobs = {"complete": {"state": "completed", "length": 33554432, "created": time.time()}, "active": {"state": "running", "created": time.time()}}
        with self.assertRaisesRegex(binary.AcquisitionError, "capacity_limit"):
            await self.manager.download_start(self.client, "https://example.com/")
        self.manager.jobs = {}

    async def test_start_manifest_failure_does_not_leak_worker_capacity(self):
        """Failed acceptance leaves no anonymous running job or cancellation state."""
        with patch.object(self.manager, "persist", side_effect=OSError("disk full")), self.assertRaises(OSError):
            await self.manager.download_start(self.client, "https://example.com/")
        self.assertFalse(self.manager.jobs)
        self.assertFalse(self.manager.events)
        self.assertFalse(self.manager.tasks)

    async def asyncTearDown(self):
        """Finish every worker before cleaning state."""
        await asyncio.gather(*list(self.manager.tasks.values()))
        os.close(self.manager.fd)
        self.temp.cleanup()

    async def start(self, **kwargs):
        """Start and join fixture. :param kwargs: Start options."""
        job = await self.manager.download_start(self.client, "https://example.com/path?token=fake", **kwargs)
        await asyncio.gather(*list(self.manager.tasks.values()))
        return await self.manager.download_status(self.client, job["job_id"])

    async def test_exact_export_ownership_idempotency_and_redaction(self):
        job = await self.start(idempotency_key="retry-key")
        repeated = await self.manager.download_start(self.client, "https://example.com/path?token=fake", idempotency_key="retry-key")
        self.assertEqual(repeated["job_id"], job["job_id"])
        self.assertEqual(self.transport.calls, 1)
        self.assertEqual(job["state"], "completed")
        for method, field in ((self.manager.download_status, "job_id"), (self.manager.download_cancel, "job_id"), (self.manager.artifact_info, "artifact_id"), (self.manager.artifact_export, "artifact_id")):
            with self.assertRaisesRegex(binary.AcquisitionError, "resource_unavailable"):
                await method(self.other, job[field])
        export = await self.manager.artifact_export(self.client, job["artifact_id"])
        again = await self.manager.artifact_export(self.client, job["artifact_id"])
        self.assertEqual(export, again)
        self.assertEqual((Path(self.temp.name)/"export"/export["filename"]).read_bytes(), self.transport.body)
        manifest = (Path(self.temp.name)/(job["job_id"]+".json")).read_text()
        for secret in ("token", "fake", self.client, "retry-key"):
            self.assertNotIn(secret, manifest + str(job) + str(export))

    async def test_bad_hash_and_interrupted_partial_never_publish(self):
        job = await self.start(expected_sha256="0"*64)
        self.assertEqual(job["error"], "hash_mismatch")
        self.assertEqual(list(Path(self.temp.name).glob("*.bin")), [])
        self.transport.error = "tor_transport_failed"
        job = await self.start()
        self.assertTrue(job["retryable"])
        self.assertEqual(list(Path(self.temp.name).glob("*.part")), [])
        self.assertEqual(list(Path(self.temp.name).glob("*.bin")), [])

    async def test_capabilities_before_io(self):
        for value in (None, "default", str(uuid.uuid1()), str(uuid.uuid4()).upper()):
            with self.assertRaises(ValueError):
                await self.manager.download_start(value, "https://example.com/")
        self.assertEqual(self.transport.calls, 0)
        with self.assertRaises(TypeError):
            await self.manager.download_start(url="https://example.com/")

    async def test_export_symlink_hardlink_and_path_rejection(self):
        job = await self.start()
        root = Path(self.temp.name)
        with tempfile.TemporaryDirectory() as outside:
            (root/"export").symlink_to(outside, target_is_directory=True)
            with self.assertRaises(OSError):
                await self.manager.artifact_export(self.client, job["artifact_id"])
            self.assertEqual(list(Path(outside).iterdir()), [])
            (root/"export").unlink()
        artifact = root/(job["artifact_id"]+".bin")
        os.link(artifact, root/"extra")
        with self.assertRaisesRegex(binary.AcquisitionError, "artifact_unsafe"):
            await self.manager.artifact_export(self.client, job["artifact_id"])
        with self.assertRaises(TypeError):
            await self.manager.artifact_export(self.client, job["artifact_id"], path="../../evil")

    async def test_restart_and_retention(self):
        job = await self.start()
        pending = dict(self.manager.jobs[job["job_id"]], state="running")
        self.manager.persist(pending)
        restarted = binary.AcquisitionManager(self.temp.name, self.transport)
        try:
            self.assertEqual(restarted.jobs[job["job_id"]]["state"], "failed")
            self.assertFalse((Path(self.temp.name)/(job["job_id"]+".bin")).exists())
            restarted.ttl = -1
            restarted.cleanup()
            self.assertEqual(restarted.jobs, {})
        finally:
            os.close(restarted.fd)

    async def test_simultaneous_idempotency_and_disk_failure(self):
        jobs = await asyncio.gather(*[self.manager.download_start(self.client, "https://example.com/", idempotency_key="same") for _ in range(8)])
        self.assertEqual(len({j["job_id"] for j in jobs}), 1)
        await asyncio.gather(*list(self.manager.tasks.values()))
        self.assertEqual(self.transport.calls, 1)
        with self.assertRaisesRegex(binary.AcquisitionError, "idempotency_conflict"):
            await self.manager.download_start(self.client, "https://other.example/", idempotency_key="same")
        def disk_error(url, output, maximum, deadline, cancelled):
            """Simulate full storage. :param url: URL. :param output: Sink. :param maximum: Cap. :param deadline: Deadline. :param cancelled: Event."""
            raise OSError("disk full secret=https://example.com/?token=fake")
        self.transport.download = disk_error
        job = await self.start()
        self.assertEqual(job["error"], "storage_or_transport_failed")
        self.assertNotIn("token", str(job))

    async def test_export_collision_never_clobbers(self):
        job = await self.start()
        root = Path(self.temp.name)/"export"
        root.mkdir(mode=0o700)
        fixed = uuid.uuid4()
        existing = root/(fixed.hex+".bin")
        existing.write_bytes(b"foreign")
        with patch.object(binary.uuid, "uuid4", return_value=fixed):
            with self.assertRaises(FileExistsError):
                await self.manager.artifact_export(self.client, job["artifact_id"])
        self.assertEqual(existing.read_bytes(), b"foreign")
        self.assertEqual(list(root.glob("*.part")), [])

    async def test_cancel_and_capacity(self):
        original = self.transport.download
        def slow(url, output, maximum, deadline, cancelled):
            """Wait for cancellation. :param url: URL. :param output: Sink. :param maximum: Cap. :param deadline: Deadline. :param cancelled: Event."""
            cancelled.wait(2)
            if cancelled.is_set():
                raise binary.AcquisitionError("cancelled")
            return original(url, output, maximum, deadline, cancelled)
        self.transport.download = slow
        job = await self.manager.download_start(self.client, "https://example.com/")
        await self.manager.download_cancel(self.client, job["job_id"])
        await asyncio.gather(*list(self.manager.tasks.values()))
        self.assertEqual(self.manager.jobs[job["job_id"]]["state"], "cancelled")
        self.manager.max_jobs = 1
        with self.assertRaisesRegex(binary.AcquisitionError, "capacity_limit"):
            await self.manager.download_start(self.client, "https://example.com/")


if __name__ == "__main__":
    unittest.main()

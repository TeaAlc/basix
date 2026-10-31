"""Bounded exact-byte Tor acquisition; no target DNS or direct target sockets."""
import asyncio
import contextlib
import hashlib
import http.client
import io
import stat
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid

POLICY_VERSION = "basix-binary-1"
TOOLS = {"download_start", "download_status", "download_cancel", "artifact_info", "artifact_export"}


class AcquisitionError(Exception):
    """Safe machine-readable error, never containing remote input."""


def client_key(client_id):
    """Validate and hash a bearer capability. :param client_id: Canonical UUID v4."""
    try:
        value = uuid.UUID(client_id)
        if value.version != 4 or str(value) != client_id or value.variant != uuid.RFC_4122:
            raise ValueError()
    except (ValueError, TypeError, AttributeError):
        raise ValueError("client_id must be a canonical UUID v4") from None
    return hashlib.sha256(client_id.encode()).hexdigest()


def public_address(value):
    """Reject non-global destinations. :param value: Canonical IP address text."""
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        raise AcquisitionError("destination_rejected") from None
    if (not address.is_global or address.is_multicast or address.is_reserved
            or (isinstance(address, ipaddress.IPv6Address) and (address.ipv4_mapped or address.sixtofour or address.teredo))):
        raise AcquisitionError("destination_rejected")
    # Keep conservative exclusions stable across Python ipaddress database versions.
    blocked = ("192.0.0.0/24", "192.88.99.0/24", "64:ff9b::/96", "64:ff9b:1::/48", "2001::/23", "3fff::/20")
    if any(address in ipaddress.ip_network(network) for network in blocked):
        raise AcquisitionError("destination_rejected")
    if address.version == 6 and address not in ipaddress.ip_network("2000::/3"):
        raise AcquisitionError("destination_rejected")
    return address


def target(url):
    """Parse a strictly bounded HTTP URL. :param url: Sensitive acquisition URL."""
    if not isinstance(url, str) or len(url) > 4096 or any(ord(c) < 33 or ord(c) > 126 for c in url) or "\\" in url or re.search(r"%0[ad]", url, re.I):
        raise AcquisitionError("url_rejected")
    try:
        parsed = urllib.parse.urlsplit(url)
        host = parsed.hostname
        if host and "%" in host:
            raise ValueError()
        port = parsed.port if parsed.port is not None else (443 if parsed.scheme == "https" else 80)
        if parsed.scheme not in {"http", "https"} or not host or parsed.username is not None or parsed.password is not None or parsed.fragment or port not in {80, 443}:
            raise ValueError()
        try:
            public_address(host)
        except AcquisitionError:
            if ":" in host or not re.fullmatch(r"(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}", host):
                raise ValueError()
        return parsed, host, port
    except ValueError:
        raise AcquisitionError("url_rejected") from None


def origin(url):
    """Return provenance without path/query secrets. :param url: Sensitive URL."""
    parsed, host, port = target(url)
    return f"{parsed.scheme}://{'[' + host + ']' if ':' in host else host}:{port}"


def receive(sock, count, deadline=None):
    """Read exactly a SOCKS field. :param sock: Proxy socket. :param count: Field length. :param deadline: Optional absolute deadline."""
    data = b""
    while len(data) < count:
        if deadline is not None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AcquisitionError("time_limit")
            sock.settimeout(min(10, remaining))
        part = sock.recv(count - len(data))
        if not part:
            raise AcquisitionError("tor_unavailable")
        data += part
    return data


class DeadlineReader(io.RawIOBase):
    """Apply the total deadline to every underlying read, including HTTP headers."""

    def __init__(self, sock, deadline):
        """Wrap socket. :param sock: Pinned socket. :param deadline: Monotonic deadline."""
        self.sock, self.deadline = sock, deadline

    def readable(self):
        """Permit buffered reads."""
        return True

    def readinto(self, buffer):
        """Read bounded bytes. :param buffer: Writable read buffer."""
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise AcquisitionError("time_limit")
        self.sock.settimeout(min(10, remaining))
        return self.sock.recv_into(buffer)


class HTTPStream:
    """Expose only a deadline-constrained socket file for HTTPResponse."""

    def __init__(self, sock, deadline):
        """Bind transport. :param sock: TLS/plain socket. :param deadline: Total deadline."""
        self.sock, self.deadline = sock, deadline

    def makefile(self, mode):
        """Create bounded reader. :param mode: HTTPResponse binary read mode."""
        if mode != "rb":
            raise AcquisitionError("internal_error")
        return io.BufferedReader(DeadlineReader(self.sock, self.deadline))


def proxy_connect(address, timeout):
    """Bound even libc alias resolution. :param address: Fixed managed alias and port. :param timeout: Remaining connection seconds."""
    if address[0] != "basix-tor-proxy" or address[1] not in (9050, 9052):
        raise AcquisitionError("proxy_configuration_rejected")
    deadline = time.monotonic() + timeout
    try:
        # libc DNS cannot be cancelled in a Python thread. A short-lived trusted
        # helper is killed/reaped by subprocess.run on timeout; no target enters it.
        result = subprocess.run(
            [sys.executable, "-c", "import socket; print(socket.gethostbyname('basix-tor-proxy'))"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True, timeout=timeout,
        )
        numeric = str(ipaddress.IPv4Address(result.stdout.decode("ascii").strip()))
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AcquisitionError("time_limit")
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            sock.settimeout(remaining)
            sock.connect((numeric, address[1]))
            return sock
        except BaseException:
            sock.close()
            raise
    except subprocess.TimeoutExpired:
        raise AcquisitionError("time_limit") from None
    except (subprocess.CalledProcessError, ValueError, UnicodeError):
        raise AcquisitionError("tor_unavailable") from None


class TorTransport:
    """Remote RESOLVE followed by numeric CONNECT, retaining HTTP Host and TLS SNI."""

    def __init__(self, proxy_host="basix-tor-proxy", timeout=10):
        """Configure trusted proxy. :param proxy_host: Managed alias. :param timeout: Socket cap."""
        if proxy_host != "basix-tor-proxy":
            raise AcquisitionError("proxy_configuration_rejected")
        self.proxy_host, self.timeout = proxy_host, timeout

    def command(self, command, address, port, deadline):
        """Exchange SOCKS request. :param command: RESOLVE/CONNECT. :param address: Target bytes. :param port: Target port. :param deadline: Total deadline."""
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AcquisitionError("time_limit")
        sock = proxy_connect((self.proxy_host, 9050 if command == 0xF0 else 9052), min(self.timeout, remaining))
        try:
            sock.sendall(b"\x05\x01\x00")
            if receive(sock, 2, deadline) != b"\x05\x00":
                raise AcquisitionError("tor_unavailable")
            sock.sendall(b"\x05" + bytes([command]) + b"\x00" + address + port.to_bytes(2, "big"))
            version, status, reserved, kind = receive(sock, 4, deadline)
            if version == 5 and status == 2 and command == 1:
                raise AcquisitionError("tor_pinning_unsupported")
            if version != 5 or status != 0 or reserved != 0 or kind not in {1, 4}:
                raise AcquisitionError("tor_unavailable")
            packed = receive(sock, 4 if kind == 1 else 16, deadline)
            receive(sock, 2, deadline)
            return sock, str(ipaddress.ip_address(packed))
        except BaseException:
            sock.close()
            raise

    def response(self, url, deadline):
        """Open one pinned response. :param url: Validated sensitive URL. :param deadline: Total deadline."""
        parsed, host, port = target(url)
        try:
            try:
                ipaddress.ip_address(host)
                address = public_address(host)
            except ValueError:
                encoded = host.encode("ascii")
                resolve, resolved = self.command(0xF0, b"\x03" + bytes([len(encoded)]) + encoded, 0, deadline)
                resolve.close()
                address = public_address(resolved)
            sock, _ = self.command(1, bytes([1 if address.version == 4 else 4]) + address.packed, port, deadline)
            try:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AcquisitionError("time_limit")
                sock.settimeout(min(self.timeout, remaining))
                if parsed.scheme == "https":
                    sock = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
                path = urllib.parse.urlunsplit(("", "", parsed.path or "/", parsed.query, ""))
                authority = f"[{host}]" if ":" in host else host
                if port != (443 if parsed.scheme == "https" else 80):
                    authority += f":{port}"
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AcquisitionError("time_limit")
                sock.settimeout(min(self.timeout, remaining))
                sock.sendall(f"GET {path} HTTP/1.1\r\nHost: {authority}\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n".encode("ascii"))
                response = http.client.HTTPResponse(HTTPStream(sock, deadline))
                response.begin()
                return response, sock
            except BaseException:
                sock.close()
                raise
        except AcquisitionError:
            raise
        except (OSError, ssl.SSLError, http.client.HTTPException):
            raise AcquisitionError("tor_transport_failed") from None

    def download(self, url, output, maximum, deadline, cancelled):
        """Stream exact body bytes. :param url: Sensitive URL. :param output: Private binary sink. :param maximum: Byte cap. :param deadline: Monotonic deadline. :param cancelled: Cancellation event."""
        chain, seen = [], set()
        for hop in range(6):
            if cancelled.is_set():
                raise AcquisitionError("cancelled")
            if time.monotonic() >= deadline:
                raise AcquisitionError("time_limit")
            if url in seen:
                raise AcquisitionError("redirect_loop")
            seen.add(url)
            chain.append(origin(url))
            response, sock = self.response(url, deadline)
            try:
                if response.status in {301, 302, 303, 307, 308}:
                    location = response.getheader("Location")
                    if not location or hop == 5:
                        raise AcquisitionError("redirect_limit")
                    next_url = urllib.parse.urljoin(url, location)
                    if target(url)[0].scheme == "https" and target(next_url)[0].scheme != "https":
                        raise AcquisitionError("https_downgrade")
                    url = next_url
                    continue
                if response.status != 200:
                    raise AcquisitionError("http_status_rejected")
                if (response.getheader("Content-Encoding") or "identity").strip().lower() != "identity":
                    raise AcquisitionError("content_encoding_rejected")
                lengths = response.headers.get_all("Content-Length") or []
                if len(lengths) > 1 or (lengths and not re.fullmatch(r"[0-9]{1,20}", lengths[0])):
                    raise AcquisitionError("content_length_rejected")
                declared = int(lengths[0]) if lengths else None
                if declared is not None and declared > maximum:
                    raise AcquisitionError("byte_limit")
                if response.getheader("Transfer-Encoding") and (lengths or response.getheader("Transfer-Encoding").lower() != "chunked"):
                    raise AcquisitionError("transfer_encoding_rejected")
                length, digest = 0, hashlib.sha256()
                while True:
                    if cancelled.is_set():
                        raise AcquisitionError("cancelled")
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise AcquisitionError("time_limit")
                    sock.settimeout(min(self.timeout, remaining))
                    block = response.read1(min(65536, maximum - length + 1))
                    if not block:
                        break
                    length += len(block)
                    if length > maximum:
                        raise AcquisitionError("byte_limit")
                    output.write(block)
                    digest.update(block)
                if declared is not None and length != declared:
                    raise AcquisitionError("incomplete_body")
                return length, digest.hexdigest(), chain
            except AcquisitionError:
                raise
            except (OSError, http.client.HTTPException):
                raise AcquisitionError("tor_transport_failed") from None
            finally:
                response.close()
                sock.close()
        raise AcquisitionError("redirect_limit")


class AcquisitionManager:
    """One process owns private, persistent, bounded artifacts and asynchronous jobs."""

    def __init__(self, root, transport=None, ready=None, max_bytes=33554432, max_jobs=128, ttl=86400):
        """Initialize state. :param root: Administrator state root. :param transport: Trusted transport/test double. :param ready: Async Tor readiness callback. :param max_bytes: Per-job cap. :param max_jobs: Retained job cap. :param ttl: Retention seconds."""
        self.root = Path(root)
        self.root.mkdir(mode=0o700, parents=False, exist_ok=True)
        info = self.root.lstat()
        if self.root.is_symlink() or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise AcquisitionError("state_root_unsafe")
        self.fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.transport, self.ready = transport or TorTransport(), ready
        self.max_bytes, self.max_jobs, self.ttl = max_bytes, max_jobs, ttl
        self.jobs, self.events, self.tasks = {}, {}, {}
        self.maintenance = None
        self.orphan_exports = set()
        self.lock = asyncio.Lock()
        for name in os.listdir(self.fd):
            if re.fullmatch(r"[0-9a-f]{32}\.(?:part|manifest)", name):
                os.unlink(name, dir_fd=self.fd)
            elif re.fullmatch(r"[0-9a-f]{32}\.json", name):
                if len(self.jobs) >= self.max_jobs:
                    raise AcquisitionError("state_capacity_exceeded")
                descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.fd)
                with os.fdopen(descriptor) as source:
                    if os.fstat(source.fileno()).st_size > 16384:
                        raise AcquisitionError("state_manifest_unsafe")
                    job = json.load(source)
                if job["state"] == "running":
                    job.update(state="failed", error="interrupted")
                if job["job_id"] != name[:-5] or not re.fullmatch(r"[0-9a-f]{64}", job["owner"]):
                    raise AcquisitionError("state_manifest_unsafe")
                if job["state"] == "completed":
                    try:
                        info = os.stat(job["job_id"] + ".bin", dir_fd=self.fd, follow_symlinks=False)
                        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size != job["length"]:
                            raise OSError()
                    except OSError:
                        job.update(state="failed", error="interrupted_publication")
                self.jobs[job["job_id"]] = job
        # Crash between data publication and manifest commit leaves no public artifact.
        for name in os.listdir(self.fd):
            if re.fullmatch(r"[0-9a-f]{32}\.bin", name) and (name[:-4] not in self.jobs or self.jobs[name[:-4]]["state"] != "completed"):
                os.unlink(name, dir_fd=self.fd)
        # Reconcile a crash before/after exporting its manifest without leaking
        # unreferenced copies or keeping partial files across process restart.
        if "export" in os.listdir(self.fd):
            export_fd = os.open("export", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
            try:
                retained = {job.get("export_name") for job in self.jobs.values() if job["state"] == "completed"}
                for name in os.listdir(export_fd):
                    if re.fullmatch(r"[0-9a-f]{32}\.(?:part|bin)", name) and name not in retained:
                        os.unlink(name, dir_fd=export_fd)
            finally:
                os.close(export_fd)
        self.cleanup()

    def persist(self, job):
        """Atomically save safe state. :param job: Redacted manifest with owner hash."""
        name = job["job_id"] + ".json"
        temporary = job["job_id"] + ".manifest"
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.fd)
            with os.fdopen(descriptor, "w") as destination:
                json.dump(job, destination)
                destination.flush()
                os.fsync(destination.fileno())
            os.replace(temporary, name, src_dir_fd=self.fd, dst_dir_fd=self.fd)
            os.fsync(self.fd)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary, dir_fd=self.fd)

    def ensure_maintenance(self):
        """Start one event-loop-owned retention task; loop shutdown cancels it."""
        if self.maintenance is None or self.maintenance.done():
            self.maintenance = asyncio.create_task(self.maintain())

    async def maintain(self):
        """Expire managed staging every minute, retrying redacted storage failures."""
        while True:
            await asyncio.sleep(60)
            try:
                async with self.lock:
                    self.cleanup()
            except OSError:
                # Failures retain capacity, never make unaccounted room.
                continue

    def cleanup(self):
        """Expire terminal jobs; active work and serialized exports are excluded."""
        for key, job in list(self.jobs.items()):
            if job["state"] != "running" and time.time() - job["created"] > self.ttl:
                for suffix in (".json", ".bin", ".part", ".manifest"):
                    try:
                        os.unlink(key + suffix, dir_fd=self.fd)
                    except FileNotFoundError:
                        pass
                if job.get("export_name"):
                    export_fd = os.open("export", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
                    try:
                        os.unlink(job["export_name"], dir_fd=export_fd)
                    except FileNotFoundError:
                        pass
                    finally:
                        os.close(export_fd)
                del self.jobs[key]

        # Retry only temporary files and positively identified failed exports.
        # Never infer ownership of a live export from its opaque filename alone.
        for name in os.listdir(self.fd):
            if re.fullmatch(r"[0-9a-f]{32}\.(?:part|manifest)", name) and name.split(".")[0] not in self.tasks:
                os.unlink(name, dir_fd=self.fd)
        if "export" in os.listdir(self.fd):
            export_fd = os.open("export", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
            try:
                for name in os.listdir(export_fd):
                    if re.fullmatch(r"[0-9a-f]{32}\.part", name) or name in self.orphan_exports:
                        os.unlink(name, dir_fd=export_fd)
                        self.orphan_exports.discard(name)
            finally:
                os.close(export_fd)

    def owned(self, client_id, resource_id):
        """Find an owned resource. :param client_id: Capability. :param resource_id: Opaque job/artifact ID."""
        owner = client_key(client_id)
        self.cleanup()
        job = self.jobs.get(resource_id)
        if job is None or job["owner"] != owner:
            raise AcquisitionError("resource_unavailable")
        return job

    @staticmethod
    def view(job):
        """Remove internal ownership/idempotency metadata. :param job: Safe manifest."""
        return {key: value for key, value in job.items() if key not in {"owner", "request_key", "idempotency"}}

    async def download_start(self, client_id: str, url: str, expected_sha256: str = None, maximum_bytes: int = 33554432, time_budget: int = 120, idempotency_key: str = None):
        """Enqueue exact acquisition. :param client_id: Capability. :param url: HTTP(S) URL. :param expected_sha256: Known digest. :param maximum_bytes: Requested cap. :param time_budget: Seconds. :param idempotency_key: Client retry key."""
        self.ensure_maintenance()
        owner = client_key(client_id)
        target(url)
        if expected_sha256 is not None and not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
            raise AcquisitionError("hash_rejected")
        if type(maximum_bytes) is not int or maximum_bytes < 1 or type(time_budget) is not int or not 1 <= time_budget <= 300:
            raise AcquisitionError("limits_rejected")
        if idempotency_key is not None and (not isinstance(idempotency_key, str) or not 1 <= len(idempotency_key) <= 128):
            raise AcquisitionError("idempotency_key_rejected")
        request = hashlib.sha256(json.dumps([url, expected_sha256, maximum_bytes, time_budget]).encode()).hexdigest()
        idem = hashlib.sha256(idempotency_key.encode()).hexdigest() if idempotency_key else None
        async with self.lock:
            self.cleanup()
            for job in self.jobs.values():
                if idem and job["owner"] == owner and job.get("idempotency") == idem:
                    if job["request_key"] != request:
                        raise AcquisitionError("idempotency_conflict")
                    return self.view(job)
            if len(self.jobs) >= self.max_jobs or sum(j["state"] == "running" for j in self.jobs.values()) >= 2 or 2 * (sum(j.get("length", 0) for j in self.jobs.values()) + (1 + sum(j["state"] == "running" for j in self.jobs.values())) * self.max_bytes) > 134217728:
                raise AcquisitionError("capacity_limit")
            if self.ready is None or not await self.ready():
                raise AcquisitionError("tor_unavailable_retryable")
            key = uuid.uuid4().hex
            job = dict(job_id=key, state="running", owner=owner, request_key=request, idempotency=idem, created=time.time(), policy=POLICY_VERSION)
            self.persist(job)
            self.jobs[key] = job
            self.events[key] = threading.Event()
            self.tasks[key] = asyncio.create_task(self.run(job, url, expected_sha256, min(maximum_bytes, self.max_bytes), time_budget))
            return self.view(job)

    async def run(self, job, url, expected, maximum, budget):
        """Publish only verified bytes. :param job: Owned state. :param url: Ephemeral URL. :param expected: Expected digest. :param maximum: Byte cap. :param budget: Seconds."""
        key = job["job_id"]
        def worker():
            """Run blocking I/O in a dedicated thread."""
            descriptor = os.open(key + ".part", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.fd)
            with os.fdopen(descriptor, "wb") as output:
                class ProgressSink:
                    """Update nonsecret byte progress without retaining body buffers."""
                    def write(self, block):
                        """Write bytes. :param block: Bounded body chunk."""
                        written = output.write(block)
                        job["bytes_received"] = job.get("bytes_received", 0) + written
                        return written
                result = self.transport.download(url, ProgressSink(), maximum, time.monotonic() + budget, self.events[key])
                output.flush()
                os.fsync(output.fileno())
                return result
        try:
            length, digest, chain = await asyncio.to_thread(worker)
            if self.events[key].is_set():
                raise AcquisitionError("cancelled")
            if expected and expected != digest:
                raise AcquisitionError("hash_mismatch")
            os.link(key + ".part", key + ".bin", src_dir_fd=self.fd, dst_dir_fd=self.fd, follow_symlinks=False)
            job.update(state="completed", artifact_id=key, length=length, sha256=digest, origins=chain, tls_verified=all(x.startswith("https:") for x in chain), completed=time.time())
        except Exception as exc:
            code = str(exc) if isinstance(exc, AcquisitionError) else "storage_or_transport_failed"
            job.update(state="cancelled" if code == "cancelled" else "failed", error=code, retryable=code.startswith("tor_") and code != "tor_pinning_unsupported")
        finally:
            try:
                os.unlink(key + ".part", dir_fd=self.fd)
            except FileNotFoundError:
                pass
            except OSError:
                job.update(state="failed", error="storage_or_transport_failed", retryable=False)
            try:
                self.persist(job)
            except OSError:
                # The in-memory result must not expose a publication whose
                # completion manifest could not be committed durably.
                job.update(state="failed", error="storage_or_transport_failed", retryable=False)
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(key + ".bin", dir_fd=self.fd)
            finally:
                self.events.pop(key, None)
                self.tasks.pop(key, None)

    async def download_status(self, client_id: str, job_id: str):
        """Inspect job without restarting it. :param client_id: Capability. :param job_id: Opaque ID."""
        return self.view(self.owned(client_id, job_id))

    async def download_cancel(self, client_id: str, job_id: str):
        """Request bounded cancellation. :param client_id: Capability. :param job_id: Opaque ID."""
        job = self.owned(client_id, job_id)
        if job["state"] == "running":
            self.events[job_id].set()
        return self.view(job)

    async def artifact_info(self, client_id: str, artifact_id: str):
        """Inspect completed artifact. :param client_id: Capability. :param artifact_id: Opaque ID."""
        job = self.owned(client_id, artifact_id)
        if job["state"] != "completed":
            raise AcquisitionError("artifact_unavailable")
        return self.view(job)

    async def artifact_export(self, client_id: str, artifact_id: str):
        """Export inside fixed state/export directory. :param client_id: Capability. :param artifact_id: Opaque ID."""
        async with self.lock:
            job = self.owned(client_id, artifact_id)
            if self.orphan_exports:
                raise AcquisitionError("storage_cleanup_pending")
            if job["state"] != "completed":
                raise AcquisitionError("artifact_unavailable")
            try:
                os.mkdir("export", 0o700, dir_fd=self.fd)
            except FileExistsError:
                pass
            export = os.open("export", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
            try:
                export_info = os.fstat(export)
                if export_info.st_uid != os.getuid() or export_info.st_mode & 0o077:
                    raise AcquisitionError("export_root_unsafe")
                if job.get("export_name"):
                    return dict(filename=job["export_name"], length=job["length"], sha256=job["sha256"])
                name = uuid.uuid4().hex + ".bin"
                source = os.open(artifact_id + ".bin", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.fd)
                try:
                    info = os.fstat(source)
                    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size != job["length"]:
                        raise AcquisitionError("artifact_unsafe")
                    temporary = uuid.uuid4().hex + ".part"
                    output = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=export)
                    digest = hashlib.sha256()
                    try:
                        with os.fdopen(output, "wb") as sink, os.fdopen(source, "rb", closefd=False) as stream:
                            for block in iter(lambda: stream.read(65536), b""):
                                sink.write(block)
                                digest.update(block)
                            sink.flush()
                            os.fsync(sink.fileno())
                        if digest.hexdigest() != job["sha256"]:
                            raise AcquisitionError("artifact_integrity_failed")
                        os.link(temporary, name, src_dir_fd=export, dst_dir_fd=export, follow_symlinks=False)
                    finally:
                        os.unlink(temporary, dir_fd=export)
                finally:
                    os.close(source)
                job["export_name"] = name
                try:
                    os.fsync(export)
                    self.persist(job)
                except OSError:
                    job.pop("export_name", None)
                    self.orphan_exports.add(name)
                    with contextlib.suppress(FileNotFoundError):
                        os.unlink(name, dir_fd=export)
                    self.orphan_exports.discard(name)
                    raise
                return dict(filename=name, length=job["length"], sha256=job["sha256"])
            finally:
                os.close(export)

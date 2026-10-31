#!/usr/bin/env python3
"""Trusted Tor-side numeric pinning gateway; control credentials never leave sidecar."""
import argparse
import asyncio
import contextlib
import fcntl
import socket
import struct
import ipaddress
from pathlib import Path
import signal

from binary_acquisition import public_address


def internal_interface():
    """Find exactly one nondefault IPv4 interface; fail closed during network attach."""
    routes = Path("/proc/net/route").read_text().splitlines()[1:]
    defaults = {line.split()[0] for line in routes if line.split()[1] == "00000000"}
    if len(defaults) != 1:
        raise RuntimeError("gateway_interface_unavailable")
    candidates, external = [], []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        for _, name in socket.if_nameindex():
            if name == "lo":
                continue
            request = struct.pack("256s", name.encode("ascii")[:15])
            try:
                address = socket.inet_ntoa(fcntl.ioctl(probe, 0x8915, request)[20:24])
                mask = socket.inet_ntoa(fcntl.ioctl(probe, 0x891b, request)[20:24])
            except OSError:
                continue
            if name in defaults:
                external.append(ipaddress.IPv4Address(address))
            else:
                candidates.append((address, ipaddress.IPv4Network(address + "/" + mask, strict=False)))
    if len(candidates) != 1 or any(address in candidates[0][1] for address in external):
        raise RuntimeError("gateway_interface_unavailable")
    address, network = candidates[0]
    if not ipaddress.IPv4Address(address).is_private or network.prefixlen < 8:
        raise RuntimeError("gateway_interface_unsafe")
    return address, network


class Gateway:
    """Bounded SOCKS numeric CONNECT gateway using reference-counted virtual mappings."""

    def __init__(self, control=None, connect=None, allowed_network=None):
        """Initialize trusted services. :param control: Test control callable. :param connect: Test SOCKS connector. :param allowed_network: Trusted internal IPv4 subnet for worker peers."""
        self.allowed_network = allowed_network
        self.control = control or self.control_command
        self.connect = connect or self.tor_connect
        self.lock = asyncio.Lock()
        self.mappings = {}
        self.active = 0
        self.failed = asyncio.Event()

    async def control_command(self, command):
        """Send one restricted internal command. :param command: Internally built MAPADDRESS command."""
        reader, writer = await asyncio.open_connection("127.0.0.1", 9051, limit=4096)
        try:
            cookie = Path("/var/lib/tor/control_auth_cookie").read_bytes().hex()
            writer.write(f"AUTHENTICATE {cookie}\r\n".encode("ascii"))
            await writer.drain()
            if await reader.readline() != b"250 OK\r\n":
                raise RuntimeError("control_unavailable")
            writer.write(command.encode("ascii") + b"\r\n")
            await writer.drain()
            lines = []
            for _ in range(8):
                line = await reader.readline()
                if not line.startswith((b"250 ", b"250-")):
                    raise RuntimeError("mapping_rejected")
                lines.append(line[4:].strip().decode("ascii"))
                if line.startswith(b"250 "):
                    return lines
            raise RuntimeError("control_response_limit")
        finally:
            writer.close()
            await writer.wait_closed()

    async def acquire(self, address):
        """Acquire one shared virtual mapping. :param address: Canonical public numeric target."""
        parsed = public_address(address)
        if str(parsed) != address:
            raise ValueError("target_rejected")
        async with self.lock:
            if self.failed.is_set():
                raise RuntimeError("gateway_unavailable")
            if address in self.mappings:
                self.mappings[address][1] += 1
                return self.mappings[address][0]
            if len(self.mappings) >= 4:
                raise RuntimeError("mapping_limit")
            try:
                lines = await asyncio.wait_for(self.control("MAPADDRESS 0.0.0.0=" + address), 3)
                pairs = [line.split("=", 1) for line in lines if "=" in line]
                if len(pairs) != 1 or pairs[0][1] != address:
                    raise RuntimeError("mapping_invalid")
                alias = ipaddress.IPv4Address(pairs[0][0])
                if alias not in ipaddress.ip_network("127.192.0.0/10"):
                    raise RuntimeError("mapping_invalid")
                self.mappings[address] = [str(alias), 1]
                return str(alias)
            except BaseException:
                # A lost control reply may have installed an unknown mapping.
                # Stop accepting streams and terminate Tor to clear all mappings.
                self.failed.set()
                raise

    async def release(self, address):
        """Release mapping after closing its stream. :param address: Canonical mapped target."""
        async with self.lock:
            mapping = self.mappings.get(address)
            if not mapping:
                return
            mapping[1] -= 1
            if mapping[1] == 0:
                alias = mapping[0]
                try:
                    await asyncio.wait_for(self.control("MAPADDRESS " + alias + "=" + alias), 3)
                    del self.mappings[address]
                except BaseException:
                    self.failed.set()
                    raise

    async def tor_connect(self, alias, port):
        """Connect only to a mapped alias through local Tor. :param alias: Virtual IPv4. :param port: Validated port."""
        reader, writer = await asyncio.open_connection("127.0.0.1", 9050, limit=65536)
        try:
            writer.write(b"\x05\x01\x00")
            await writer.drain()
            if await reader.readexactly(2) != b"\x05\x00":
                raise RuntimeError("socks_unavailable")
            writer.write(b"\x05\x01\x00\x01" + ipaddress.IPv4Address(alias).packed + port.to_bytes(2, "big"))
            await writer.drain()
            version, status, reserved, kind = await reader.readexactly(4)
            if (version, status, reserved) != (5, 0, 0) or kind not in (1, 4):
                raise RuntimeError("pinned_connect_failed")
            await reader.readexactly((4 if kind == 1 else 16) + 2)
            return reader, writer
        except BaseException:
            writer.close()
            await writer.wait_closed()
            raise

    async def relay(self, reader, writer):
        """Relay bounded chunks. :param reader: Source stream. :param writer: Destination stream."""
        while True:
            block = await asyncio.wait_for(reader.read(65536), 15)
            if not block:
                return
            writer.write(block)
            await asyncio.wait_for(writer.drain(), 15)

    async def handle(self, reader, writer):
        """Serve restricted SOCKS connection. :param reader: Worker stream. :param writer: Worker reply stream."""
        peer = writer.get_extra_info("peername") if self.allowed_network is not None else None
        permitted = self.allowed_network is None or (peer is not None and (ipaddress.ip_address(peer[0]).is_loopback or ipaddress.ip_address(peer[0]) in self.allowed_network))
        if not permitted or self.active >= 4:
            writer.close()
            await writer.wait_closed()
            return
        self.active += 1
        address, remote = None, None
        try:
            async with asyncio.timeout(310):
                async with asyncio.timeout(5):
                    if await reader.readexactly(3) != b"\x05\x01\x00":
                        raise ValueError("negotiation_rejected")
                    writer.write(b"\x05\x00")
                    await writer.drain()
                    version, command, reserved, kind = await reader.readexactly(4)
                    if (version, command, reserved) != (5, 1, 0) or kind not in (1, 4):
                        raise ValueError("numeric_connect_required")
                    packed = await reader.readexactly(4 if kind == 1 else 16)
                    candidate = str(ipaddress.ip_address(packed))
                    public_address(candidate)
                    port = int.from_bytes(await reader.readexactly(2), "big")
                    if port not in (80, 443):
                        raise ValueError("port_rejected")
                    alias = await self.acquire(candidate)
                    address = candidate
                remote_reader, remote = await asyncio.wait_for(self.connect(alias, port), 10)
                writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
                await writer.drain()
                tasks = [asyncio.create_task(self.relay(reader, remote)), asyncio.create_task(self.relay(remote_reader, writer))]
                try:
                    await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                finally:
                    for task in tasks:
                        task.cancel()
                    await asyncio.gather(*tasks, return_exceptions=True)
        except (Exception, asyncio.CancelledError):
            # No target, credential, or raw protocol error is logged or reflected.
            with contextlib.suppress(Exception):
                writer.write(b"\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00")
                await writer.drain()
        finally:
            if remote:
                remote.close()
                with contextlib.suppress(Exception):
                    await remote.wait_closed()
            if address:
                with contextlib.suppress(Exception):
                    await self.release(address)
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()
            self.active -= 1


async def run():
    """Start Tor and trusted gateway together; their lifetime ends as one unit."""
    # The launcher attaches the internal network immediately after container run.
    async with asyncio.timeout(20):
        while True:
            try:
                address, network = internal_interface()
                break
            except RuntimeError:
                await asyncio.sleep(.1)
    gateway = Gateway(allowed_network=network)
    server = await asyncio.start_server(gateway.handle, [address, "127.0.0.1"], 9052, limit=65536)
    tor = await asyncio.create_subprocess_exec("tor", "-f", "/etc/tor/torrc")
    loop = asyncio.get_running_loop()
    stopped = asyncio.Event()
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        loop.add_signal_handler(number, stopped.set)
    tor_wait, stop_wait = asyncio.create_task(tor.wait()), asyncio.create_task(stopped.wait())
    failed_wait = asyncio.create_task(gateway.failed.wait())
    try:
        async with server:
            await asyncio.wait([tor_wait, stop_wait, failed_wait], return_when=asyncio.FIRST_COMPLETED)
    finally:
        if tor.returncode is None:
            tor.terminate()
            try:
                await asyncio.wait_for(tor.wait(), 5)
            except asyncio.TimeoutError:
                tor.kill()
                await tor.wait()
        stop_wait.cancel()
        failed_wait.cancel()
        await asyncio.gather(tor_wait, stop_wait, failed_wait, return_exceptions=True)
    return 1 if gateway.failed.is_set() else (tor.returncode or 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    raise SystemExit(asyncio.run(run()))

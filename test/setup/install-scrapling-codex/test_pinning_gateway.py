#!/usr/bin/env python3
"""Trusted pinning gateway mapping, capability and relay boundaries."""
import asyncio
import ipaddress
from pathlib import Path
import sys
import unittest
from unittest.mock import AsyncMock, patch
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "src/setup/scrapling-tor"))
from pinning_gateway import Gateway
from binary_acquisition import AcquisitionError


class Writer:
    """Minimal in-memory protocol sink."""
    def __init__(self):
        """Initialize captured replies."""
        self.body = bytearray()
        self.closed = False
    def write(self, data):
        """Capture protocol bytes. :param data: Reply bytes."""
        self.body.extend(data)
    async def drain(self):
        """Complete buffered write."""
    def close(self):
        """Mark closed."""
        self.closed = True
    async def wait_closed(self):
        """Finish closure."""


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    """Exercise isolation without an external Tor dependency."""
    async def test_external_peer_rejected_before_socks_or_control(self):
        """Even routed packets from an egress peer cannot consume the gateway."""
        gateway = Gateway(control=AsyncMock(), allowed_network=ipaddress.ip_network("10.89.1.0/24"))
        writer = Writer()
        writer.get_extra_info = lambda name: ("10.89.0.2", 12345)
        await gateway.handle(asyncio.StreamReader(), writer)
        self.assertTrue(writer.closed)
        self.assertEqual(writer.body, b"")
        self.assertEqual(gateway.active, 0)
        gateway.control.assert_not_awaited()

    async def test_repeated_mapping_and_failed_stream_cycles_do_not_grow(self):
        """Repeated connection failures release every mapping and active stream slot."""
        control = AsyncMock(side_effect=lambda command: ["127.192.0.1=" + command.split("=", 1)[1]])
        gateway = Gateway(control=control, connect=AsyncMock(side_effect=OSError("outage")))
        for _ in range(32):
            reader, writer = asyncio.StreamReader(), Writer()
            reader.feed_data(b"\x05\x01\x00\x05\x01\x00\x01\x01\x01\x01\x01\x01\xbb")
            reader.feed_eof()
            await gateway.handle(reader, writer)
            self.assertEqual(gateway.active, 0)
            self.assertEqual(gateway.mappings, {})
            self.assertFalse(gateway.failed.is_set())
        self.assertEqual(control.await_count, 64)

    async def test_same_target_refcount_and_cleanup(self):
        """Concurrent same-target streams share exactly one map and one unmap."""
        control = AsyncMock(side_effect=[["127.192.0.1=93.184.216.34"], ["127.192.0.1=127.192.0.1"]])
        gateway = Gateway(control=control)
        aliases = await asyncio.gather(*(gateway.acquire("93.184.216.34") for _ in range(4)))
        self.assertEqual(aliases, ["127.192.0.1"] * 4)
        self.assertEqual(control.await_count, 1)
        await asyncio.gather(*(gateway.release("93.184.216.34") for _ in range(4)))
        self.assertEqual(control.await_count, 2)
        self.assertEqual(gateway.mappings, {})
        self.assertEqual(control.await_args.args, ("MAPADDRESS 127.192.0.1=127.192.0.1",))

    async def test_reject_special_addresses_before_control(self):
        """Hostnames, alternate numerics and special ranges never reach control."""
        control = AsyncMock()
        gateway = Gateway(control=control)
        for address in ("example.com", "127.0.0.1", "169.254.169.254", "::ffff:93.184.216.34", "2002:5db8:d822::", "2130706433", "127.192.0.1", "224.0.0.1"):
            with self.assertRaises((ValueError, AcquisitionError)):
                await gateway.acquire(address)
        control.assert_not_awaited()

    async def test_uncertain_control_failure_stops_new_mappings(self):
        """Unknown mapping state requires Tor restart, with no hostname fallback."""
        control = AsyncMock(side_effect=OSError("private credential"))
        gateway = Gateway(control=control)
        with self.assertRaises(OSError):
            await gateway.acquire("93.184.216.34")
        self.assertTrue(gateway.failed.is_set())
        with self.assertRaises(RuntimeError):
            await gateway.acquire("1.1.1.1")
        self.assertEqual(control.await_count, 1)

    async def test_cleanup_failure_poisoned_gateway(self):
        """Unmap failure stops service rather than leaking fresh mappings."""
        gateway = Gateway(control=AsyncMock(side_effect=[["127.192.0.1=1.1.1.1"], OSError()]))
        await gateway.acquire("1.1.1.1")
        with self.assertRaises(OSError):
            await gateway.release("1.1.1.1")
        self.assertTrue(gateway.failed.is_set())

    async def test_mapping_reply_validation_and_capacity(self):
        """Only expected virtual aliases and bounded active mappings are accepted."""
        for reply in (["127.0.0.1=1.1.1.1"], ["127.192.0.1=8.8.8.8"], ["OK"]):
            gateway = Gateway(control=AsyncMock(return_value=reply))
            with self.assertRaises((RuntimeError, ValueError)):
                await gateway.acquire("1.1.1.1")
            self.assertTrue(gateway.failed.is_set())
        gateway = Gateway(control=AsyncMock())
        gateway.mappings = {str(index): ["127.192.0.1", 1] for index in range(4)}
        with self.assertRaisesRegex(RuntimeError, "limit"):
            await gateway.acquire("1.1.1.1")
        gateway.control.assert_not_awaited()

    async def test_protocol_rejects_hostname_port_and_private(self):
        """Worker cannot issue RESOLVE, control commands, hostname or private CONNECT."""
        for request in (b"\x05\x01\x00\x03\x0bexample.com\x01\xbb", b"\x05\xf0\x00\x01" + b"\x01"*4 + b"\x00\x50", b"\x05\x01\x00\x01\x7f\x00\x00\x01\x00\x50", b"\x05\x01\x00\x01\x01\x01\x01\x01\x00\x16"):
            gateway = Gateway(control=AsyncMock(), connect=AsyncMock())
            reader, writer = asyncio.StreamReader(), Writer()
            reader.feed_data(b"\x05\x01\x00" + request)
            reader.feed_eof()
            await gateway.handle(reader, writer)
            gateway.control.assert_not_awaited()
            gateway.connect.assert_not_awaited()
            self.assertTrue(writer.closed)
            self.assertNotIn(b"AUTHENTICATE", writer.body)

    async def test_connect_failure_removes_mapping(self):
        """Failed numeric stream still unmaps without reflecting sensitive errors."""
        control = AsyncMock(side_effect=[["127.192.0.1=1.1.1.1"], ["127.192.0.1=127.192.0.1"]])
        gateway = Gateway(control=control, connect=AsyncMock(side_effect=OSError("secret")))
        reader, writer = asyncio.StreamReader(), Writer()
        reader.feed_data(b"\x05\x01\x00\x05\x01\x00\x01\x01\x01\x01\x01\x01\xbb")
        reader.feed_eof()
        await gateway.handle(reader, writer)
        self.assertEqual(gateway.mappings, {})
        self.assertEqual(gateway.active, 0)
        self.assertNotIn(b"secret", writer.body)
        gateway.connect.assert_awaited_once_with("127.192.0.1", 443)

if __name__ == "__main__":
    unittest.main()

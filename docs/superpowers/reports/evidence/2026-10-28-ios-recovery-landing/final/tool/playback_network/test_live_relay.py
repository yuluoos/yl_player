import asyncio
import io
import json
import unittest
from network_profile import Profile
try:
    from live_relay import LiveRelay
except ImportError:
    LiveRelay = None


def profile(steps=None):
    return Profile(dict(id='owned-v1', steps=steps or [
        dict(atMs=0, bytesPerSecond=1000000, latencyMs=0)]))


class RelayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.assertIsNotNone(LiveRelay, 'Live protocol shaping is missing')
        self.peers = set()
        self.log = io.StringIO()

    async def asyncTearDown(self):
        if hasattr(self, 'relay'):
            await self.relay.close()
        if hasattr(self, 'peer'):
            self.peer.close()
            await self.peer.wait_closed()
        for writer in self.peers:
            writer.close()
            await writer.wait_closed()

    async def start(self, handler, steps=None, **kwargs):
        async def serve(reader, writer):
            self.peers.add(writer)
            try:
                await handler(reader, writer)
            finally:
                writer.close()
                await writer.wait_closed()
                self.peers.discard(writer)
        self.peer = await asyncio.start_server(serve, '127.0.0.1', 0)
        self.relay = LiveRelay(profile(steps), self.log, run_id='live-1',
            protocol=kwargs.pop('protocol', 'rtmp'), media_hash='a'*64,
            upstream_port=self.peer.sockets[0].getsockname()[1], **kwargs)
        await self.relay.start()
        return self.relay.port

    async def test_transparent_http_and_rtmp_bytes_and_private_trace(self):
        async def echo(reader, writer):
            data = await reader.readexactly(23)
            writer.write(data[::-1]); await writer.drain()
        port = await self.start(echo)
        reader, writer = await asyncio.open_connection('127.0.0.1', port)
        payload = b'\x03RTMP-secret-token-1234'
        writer.write(payload); await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.read(), 2), payload[::-1])
        writer.close(); await writer.wait_closed()
        await self.relay.close()
        rows = [json.loads(v) for v in self.log.getvalue().splitlines()]
        self.assertEqual(rows[0]['upstreamBytesWritten'], 23)
        self.assertEqual(rows[0]['downstreamBytesWritten'], 23)
        self.assertEqual(rows[0]['phaseBytes'], [23])
        self.assertNotIn('secret', self.log.getvalue())
        self.assertTrue(self.relay.receipt()['cleaned'])

    async def test_stalled_connection_and_shutdown_are_bounded(self):
        async def peer(reader, writer):
            await reader.readexactly(1)
            writer.write(b'x'*1024); await writer.drain()
            await reader.read()
        port = await self.start(peer, [dict(atMs=0, bytesPerSecond=0, latencyMs=0)])
        reader, writer = await asyncio.open_connection('127.0.0.1', port)
        writer.write(b'a'); await writer.drain()
        await asyncio.sleep(.05)
        await asyncio.wait_for(self.relay.close(), 1)
        self.assertEqual(await asyncio.wait_for(reader.read(), 1), b'')
        writer.close(); await writer.wait_closed()
        self.assertEqual(self.relay.receipt()['activeConnections'], 0)
        self.assertEqual(json.loads(self.log.getvalue())['outcome'], 'cancelled')

    async def test_idle_connection_drops_at_boundary_and_reconnect_does_not_reset(self):
        async def peer(reader, writer):
            await reader.read()
        port = await self.start(peer, [
            dict(atMs=0, bytesPerSecond=1000000, latencyMs=0),
            dict(atMs=70, bytesPerSecond=0, latencyMs=0, disconnect=True),
            dict(atMs=180, bytesPerSecond=1000000, latencyMs=0)])
        reader, writer = await asyncio.open_connection('127.0.0.1', port)
        writer.write(b'hello'); await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.read(), 1), b'')
        origin = self.relay.origin
        writer.close(); await writer.wait_closed()
        await asyncio.sleep(.15)
        reader, writer = await asyncio.open_connection('127.0.0.1', port)
        writer.write(b'again'); await writer.drain()
        await asyncio.sleep(.02)
        self.assertEqual(self.relay.origin, origin)
        writer.close(); await writer.wait_closed()
        await self.relay.close()
        self.assertIn('disconnected', self.log.getvalue())

    async def test_skipped_disconnect_window_closes_old_connection_but_allows_reconnect(self):
        received = asyncio.Event()
        async def peer(reader, writer):
            await reader.readexactly(5)
            received.set()
            await reader.read()
        port = await self.start(peer, [
            dict(atMs=0, bytesPerSecond=1000000, latencyMs=0),
            dict(atMs=70, bytesPerSecond=0, latencyMs=0, disconnect=True),
            dict(atMs=180, bytesPerSecond=1000000, latencyMs=0)])
        elapsed = 0.0
        self.relay.elapsed = lambda: elapsed
        reader, writer = await asyncio.open_connection('127.0.0.1', port)
        try:
            writer.write(b'hello'); await writer.drain()
            await asyncio.wait_for(received.wait(), 1)
            # A delayed poll skips the disconnect interval entirely.
            elapsed = .2
            self.assertEqual(await asyncio.wait_for(reader.read(), 1), b'')
        finally:
            writer.close(); await writer.wait_closed()
        received.clear()
        origin = self.relay.origin
        reader, writer = await asyncio.open_connection('127.0.0.1', port)
        writer.write(b'again'); await writer.drain()
        await asyncio.wait_for(received.wait(), 1)
        self.assertFalse(reader.at_eof())
        self.assertEqual(self.relay.origin, origin)
        writer.close(); await writer.wait_closed()
        await self.relay.close()
        rows = [json.loads(line) for line in self.log.getvalue().splitlines()]
        self.assertEqual(rows[0]['outcome'], 'disconnected')
        self.assertEqual(rows[0]['downstreamBytesWritten'], 0)
        self.assertEqual(rows[1]['upstreamBytesWritten'], 5)
        self.assertNotEqual(rows[1]['outcome'], 'disconnected')

    async def test_connection_limit_refuses_extra_clients(self):
        async def peer(reader, writer):
            await reader.read()
        port = await self.start(peer, max_connections=1)
        reader, writer = await asyncio.open_connection('127.0.0.1', port)
        writer.write(b'a'); await writer.drain()
        extra_reader, extra = await asyncio.open_connection('127.0.0.1', port)
        self.assertEqual(await asyncio.wait_for(extra_reader.read(), 1), b'')
        extra.close(); await extra.wait_closed()
        writer.close(); await writer.wait_closed()
        await self.relay.close()
        self.assertEqual(self.relay.receipt()['rejectedConnections'], 1)

    async def test_invalid_identity_protocol_and_endpoint_refused_before_listening(self):
        for change in [dict(protocol='ftp'), dict(upstream_port=0),
                       dict(media_hash='secret'), dict(run_id='../secret'),
                       dict(max_connections=0), dict(connection_timeout=0)]:
            values = dict(run_id='a', protocol='hls', media_hash='a'*64,
                          upstream_port=1234)
            values.update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                LiveRelay(profile(), self.log, **values)

if __name__ == '__main__':
    unittest.main()

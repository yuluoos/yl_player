#!/usr/bin/env python3
"""Bounded, loopback-only downstream shaping for owned HLS, HTTP-FLV and RTMP.

Transparent TCP bytes, including HTTP/RTMP headers, share the profile budget.
This is not packet RTT emulation. Upload is backpressured but not rate shaped.
"""
import argparse
import asyncio
import contextlib
import json
from pathlib import Path
import re
import signal
import time

from network_profile import Disconnected, integer, load_profiles


class LiveRelay:
    def __init__(self, profile, log, *, run_id, protocol, media_hash,
                 upstream_port, max_connections=8, connection_timeout=120):
        if (not isinstance(run_id, str) or
                not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}', run_id) or
                protocol not in ('hls', 'flv', 'rtmp') or
                not isinstance(media_hash, str) or
                not re.fullmatch(r'[0-9a-f]{64}', media_hash) or
                not integer(upstream_port, 65535) or upstream_port == 0 or
                not integer(max_connections, 8) or max_connections == 0 or
                not integer(connection_timeout, 120) or connection_timeout == 0):
            raise ValueError('Invalid owned relay configuration')
        self.profile, self.log = profile, log
        self.run_id, self.protocol, self.media_hash = run_id, protocol, media_hash
        self.upstream_port = upstream_port
        self.max_connections, self.connection_timeout = max_connections, connection_timeout
        self.origin = None
        self.tasks = set()
        self.retiring = set()
        self.writers = set()
        self.lock = asyncio.Lock()
        self.server = None
        self.closed = False
        self.accepted = self.rejected = self.recorded = 0

    async def start(self, port=0):
        if self.server is not None or self.closed or not integer(port, 65535):
            raise ValueError('Invalid relay start')
        self.server = await asyncio.start_server(self.accept, '127.0.0.1', port,
                                                 limit=16384, backlog=8)
        self.port = self.server.sockets[0].getsockname()[1]

    def elapsed(self):
        return 0 if self.origin is None else time.monotonic() - self.origin

    def state(self):
        elapsed = self.elapsed()
        step, boundary = self.profile.at(elapsed)
        if self.closed or step['disconnect']:
            raise Disconnected()
        return elapsed, step, boundary

    async def consume(self, count):
        async with self.lock:
            remaining = count
            while remaining > 1e-7:
                elapsed, step, boundary = self.state()
                rate = step['bytesPerSecond']
                delay = min(.02, boundary - elapsed,
                            remaining / rate if rate else float('inf'))
                await asyncio.sleep(delay)
                remaining -= delay * rate
            self.state()

    def accept(self, reader, writer):
        if self.closed or len(self.tasks) >= self.max_connections or self.accepted >= 10000:
            self.rejected += 1
            writer.close()
            return
        self.accepted += 1
        task = asyncio.create_task(self.handle(reader, writer, self.accepted))
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    async def handle(self, reader, writer, identity):
        self.writers.add(writer)
        peer_writer = None
        children = []
        row = dict(schemaVersion=1, runId=self.run_id, protocol=self.protocol,
                   profileId=self.profile.id, profileHash=self.profile.sha256,
                   declaredMediaHash=self.media_hash, connectionId=identity,
                   startMs=None, endMs=None, upstreamBytesWritten=0,
                   downstreamBytesWritten=0, phaseBytes=[0]*len(self.profile.steps),
                   outcome='complete')
        try:
            async with asyncio.timeout(self.connection_timeout):
                # TCP health checks do not arm the timeline. First real client
                # bytes arm it once, shared by all reconnects and protocols.
                first = await reader.read(1024)
                if not first:
                    return
                if self.origin is None:
                    self.origin = time.monotonic()
                row['startMs'] = self.elapsed()*1000
                elapsed, step, _ = self.state()
                until = elapsed + step['latencyMs']/1000
                while self.elapsed() < until:
                    self.state()
                    await asyncio.sleep(min(.02, until-self.elapsed()))
                peer_reader, peer_writer = await asyncio.open_connection(
                    '127.0.0.1', self.upstream_port, limit=16384)
                self.writers.add(peer_writer)
                peer_writer.write(first)
                await peer_writer.drain()
                row['upstreamBytesWritten'] += len(first)

                async def upstream():
                    while data := await reader.read(1024):
                        self.state()
                        peer_writer.write(data)
                        await peer_writer.drain()
                        row['upstreamBytesWritten'] += len(data)

                async def downstream():
                    while data := await peer_reader.read(1024):
                        await self.consume(len(data))
                        writer.write(data)
                        await writer.drain()
                        row['downstreamBytesWritten'] += len(data)
                        index = max(i for i, s in enumerate(self.profile.steps)
                                    if s['atMs'] <= self.elapsed()*1000)
                        row['phaseBytes'][index] += len(data)

                async def watch_profile():
                    # Disconnect applies even to silent/paused peers.
                    while True:
                        self.state()
                        await asyncio.sleep(.02)

                children = [asyncio.create_task(c()) for c in
                            (upstream, downstream, watch_profile)]
                done, _ = await asyncio.wait(children, return_when=asyncio.FIRST_COMPLETED)
                for child in done:
                    child.result()
        except Disconnected:
            row['outcome'] = 'cancelled' if self.closed else 'disconnected'
        except TimeoutError:
            row['outcome'] = 'timeout'
        except (OSError, ConnectionError):
            row['outcome'] = 'io_error'
        except asyncio.CancelledError:
            row['outcome'] = 'cancelled'
        finally:
            self.retiring.add(asyncio.current_task())
            for child in children:
                child.cancel()
            await asyncio.gather(*children, return_exceptions=True)
            for out in (writer, peer_writer):
                if out is not None:
                    out.close()
                    with contextlib.suppress(OSError, TimeoutError):
                        await asyncio.wait_for(out.wait_closed(), .5)
                    self.writers.discard(out)
            row['endMs'] = self.elapsed()*1000 if row['startMs'] is not None else None
            self.log.write(json.dumps(row, sort_keys=True)+'\n')
            self.log.flush()
            self.recorded += 1
            self.retiring.discard(asyncio.current_task())

    async def close(self):
        self.closed = True
        if self.server is not None:
            self.server.close()
            await self.server.wait_closed()
        tasks = list(self.tasks)
        for task in tasks:
            if task not in self.retiring:
                task.cancel()
        for writer in list(self.writers):
            writer.close()
        await asyncio.gather(*tasks, return_exceptions=True)
        self.tasks.difference_update(tasks)

    def receipt(self):
        return dict(schemaVersion=1, runId=self.run_id, protocol=self.protocol,
                    profileId=self.profile.id, profileHash=self.profile.sha256,
                    declaredMediaHash=self.media_hash,
                    acceptedConnections=self.accepted, rejectedConnections=self.rejected,
                    recordedConnections=self.recorded, activeConnections=len(self.tasks),
                    cleaned=self.closed and not self.tasks and not self.writers,
                    timelineMode='first-client-bytes',
                    byteScope='downstream-tcp-including-protocol-headers',
                    phaseBoundariesMs=[s['atMs'] for s in self.profile.steps],
                    physicalOutputVerified=False, endToEndLatencyUs=None)


async def run(args):
    profiles = load_profiles(args.profiles)
    if args.profile not in profiles:
        raise ValueError('Unknown network profile')
    with args.log.open('x') as log, args.receipt.open('x') as receipt:
        relay = LiveRelay(profiles[args.profile], log, run_id=args.run_id,
                          protocol=args.protocol, media_hash=args.media_hash,
                          upstream_port=args.upstream_port)
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, stop.set)
        try:
            await relay.start(args.port)
            print(json.dumps(dict(port=relay.port, **relay.receipt())), flush=True)
            await stop.wait()
        finally:
            await relay.close()
            json.dump(relay.receipt(), receipt, indent=2)
            receipt.write('\n')
            for sig in (signal.SIGINT, signal.SIGTERM):
                loop.remove_signal_handler(sig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profiles', type=Path, default=Path(__file__).with_name('profiles.json'))
    parser.add_argument('--profile', default='down-and-recover-v1')
    parser.add_argument('--protocol', choices=['hls', 'flv', 'rtmp'], required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--media-hash', required=True)
    parser.add_argument('--upstream-port', type=int, required=True)
    parser.add_argument('--port', type=int, default=18780)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    try:
        asyncio.run(run(args))
    except (ValueError, OSError):
        parser.exit(2, 'Invalid configuration or unavailable local relay resources\n')

if __name__ == '__main__':
    main()

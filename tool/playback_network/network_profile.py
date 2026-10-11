#!/usr/bin/env python3
"""Loopback HTTP fixture server with a shared, versioned shaping timeline.

Only SHA256SUMS-listed immutable fixture bytes are served. No proxying, native
player changes, global network settings, or inferred playback measurements.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
from pathlib import Path, PurePosixPath
import re
import socket
import threading
import time
from urllib.parse import unquote, urlsplit


class Disconnected(Exception):
    pass


def integer(value, maximum):
    return type(value) is int and 0 <= value <= maximum


class Profile:
    def __init__(self, data):
        if (not isinstance(data, dict) or set(data) != {'id', 'steps'} or
                not isinstance(data['id'], str) or
                not re.fullmatch(r'[a-z0-9-]{1,80}-v[1-9][0-9]*', data['id'])):
            raise ValueError('invalid profile identity')
        steps = data['steps']
        if not isinstance(steps, list) or not 1 <= len(steps) <= 256:
            raise ValueError('invalid profile steps')
        previous = -1
        self.steps = []
        for s in steps:
            if (not isinstance(s, dict) or
                    not {'atMs', 'bytesPerSecond', 'latencyMs'} <= s.keys() or
                    s.keys() - {'atMs', 'bytesPerSecond', 'latencyMs', 'disconnect'} or
                    not integer(s['atMs'], 86400000) or
                    not integer(s['bytesPerSecond'], 1000000000) or
                    not integer(s['latencyMs'], 120000) or
                    type(s.get('disconnect', False)) is not bool or
                    s['atMs'] <= previous):
                raise ValueError('invalid profile step')
            previous = s['atMs']
            self.steps.append(dict(s, disconnect=s.get('disconnect', False)))
        if self.steps[0]['atMs'] != 0:
            raise ValueError('profile must start at zero')
        self.id = data['id']
        self.sha256 = hashlib.sha256(json.dumps(
            dict(id=self.id, steps=self.steps), sort_keys=True,
            separators=(',', ':')).encode()).hexdigest()

    def at(self, elapsed):
        index = 0
        while (index + 1 < len(self.steps) and
               elapsed >= self.steps[index + 1]['atMs'] / 1000):
            index += 1
        boundary = (self.steps[index + 1]['atMs'] / 1000
                    if index + 1 < len(self.steps) else math.inf)
        return self.steps[index], boundary


def load_profiles(path):
    data = json.loads(Path(path).read_text())
    if (not isinstance(data, dict) or set(data) != {'schemaVersion', 'profiles'} or
            type(data['schemaVersion']) is not int or data['schemaVersion'] != 1 or
            not isinstance(data['profiles'], list) or not 1 <= len(data['profiles']) <= 64):
        raise ValueError('invalid profile document')
    result = {}
    for item in data['profiles']:
        p = Profile(item)
        if p.id in result:
            raise ValueError('duplicate profile id')
        result[p.id] = p
    return result


class Shaper:
    """All connections share one budget; no credit is saved during idle time.

    Deadline/elapsed values use seconds relative to the shaper's origin. A
    response snapshots its initial application latency; transfer rate and
    disconnect state follow the current global step, including in-flight work.
    """
    def __init__(self, profile, now=time.monotonic, sleep=time.sleep):
        self.profile, self.now, self.sleep = profile, now, sleep
        self.origin = now()
        self.lock = threading.Lock()
        self.stopped = threading.Event()

    def elapsed(self):
        return self.now() - self.origin

    def state(self, deadline):
        elapsed = self.elapsed()
        if self.stopped.is_set():
            raise Disconnected()
        if elapsed >= deadline:
            raise TimeoutError()
        step, boundary = self.profile.at(elapsed)
        if step['disconnect']:
            raise Disconnected()
        return elapsed, step, min(boundary, deadline)

    def begin(self, deadline):
        elapsed, step, _ = self.state(deadline)
        target = elapsed + step['latencyMs'] / 1000
        while self.elapsed() < target:
            elapsed, _, boundary = self.state(deadline)
            self.sleep(min(target - elapsed, boundary - elapsed, .05))
        self.state(deadline)

    def consume(self, count, deadline):
        with self.lock:
            remaining = float(count)
            while remaining > 1e-7:
                elapsed, step, boundary = self.state(deadline)
                rate = step['bytesPerSecond']
                duration = min(boundary - elapsed, .05,
                               remaining / rate if rate else math.inf)
                self.sleep(duration)
                # Use scheduled time, never oversleep as credit for a burst.
                remaining -= duration * rate
            self.state(deadline)


def load_assets(root):
    """Preload at most 64 MiB/4096 files and verify the frozen SHA256SUMS."""
    root = Path(root).resolve()
    inventory = root / 'SHA256SUMS'
    if inventory.stat().st_size > 1024 * 1024:
        raise ValueError('fixture inventory too large')
    assets, total = {}, 0
    for line in inventory.read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  (?:\./)?(.+)', line)
        if not match:
            raise ValueError('invalid fixture inventory')
        expected, name = match.groups()
        relative = PurePosixPath(name)
        if (relative.is_absolute() or '..' in relative.parts or
                str(relative) != name or '\\' in name or
                not re.fullmatch(r'[A-Za-z0-9_./-]+', name) or name in assets):
            raise ValueError('invalid fixture path')
        path = root / name
        if any(p.is_symlink() for p in [path, *path.parents] if p != root):
            raise ValueError('symlink fixture path')
        total += path.stat().st_size
        if total > 64 * 1024 * 1024 or len(assets) >= 4096:
            raise ValueError('fixture budget exceeded')
        with path.open('rb') as source:
            body = source.read(64 * 1024 * 1024 + 1)
        if len(body) > 64 * 1024 * 1024 or hashlib.sha256(body).hexdigest() != expected:
            raise ValueError('fixture hash mismatch')
        assets[name] = body
    if not assets:
        raise ValueError('empty fixture inventory')
    return assets


def byte_range(value, length):
    if value is None:
        return 0, length
    match = re.fullmatch(r'bytes=([0-9]*)-([0-9]*)', value)
    if not match or not any(match.groups()) or length == 0:
        raise ValueError('invalid range')
    first, last = match.groups()
    if first:
        start = int(first)
        end = min(int(last) + 1, length) if last else length
    else:
        start, end = max(0, length - int(last)), length
    if not 0 <= start < end <= length:
        raise ValueError('unsatisfiable range')
    return start, end


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = False
    request_queue_size = 8

    def __init__(self, root, profile, log, port, now, sleep):
        self.assets = load_assets(root)
        self.shaper = Shaper(profile, now, sleep)
        self.log = log
        self.records_lock = threading.Lock()
        self.handlers = threading.Condition()
        self.active = 0
        self.requests = 0
        self.rejected_requests = 0
        self.next_record_id = 0
        self.connection_timeout = 120
        self.active_sockets = set()
        super().__init__(('127.0.0.1', port), Handler)

    def process_request(self, request, client_address):
        with self.handlers:
            if self.active >= 8 or self.requests >= 10000:
                # Bounded threads/log; overload is not a shaped media request.
                self.rejected_requests += 1
                self.shutdown_request(request)
                return
            self.active += 1
            self.requests += 1
            self.active_sockets.add(request)
            self.handlers.notify_all()
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            with self.handlers:
                self.active -= 1
                self.active_sockets.discard(request)
                self.handlers.notify_all()

    def wait_handlers(self):
        with self.handlers:
            return self.handlers.wait_for(lambda: self.active == 0, timeout=5)

    def server_close(self):
        self.shaper.stopped.set()
        with self.handlers:
            for connection in self.active_sockets:
                interrupt_socket(connection)
        super().server_close()

    def handle_error(self, request, client_address):
        # Never print incoming URLs/headers or exception text.
        pass


def interrupt_socket(connection):
    try:
        connection.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'  # One request/connection, no hidden keepalive.

    def setup(self):
        self.request.settimeout(2)
        super().setup()
        # Inactivity timeout alone does not bound a slowly trickling header.
        self.connection_timer = threading.Timer(
            self.server.connection_timeout, interrupt_socket, args=(self.request,))
        self.connection_timer.daemon = True
        self.connection_timer.start()

    def finish(self):
        self.connection_timer.cancel()
        super().finish()

    def log_message(self, format, *args):
        pass

    def do_HEAD(self):
        self.serve(head=True)

    def do_GET(self):
        self.serve(head=False)

    def serve(self, head):
        s = self.server.shaper
        started = s.elapsed()
        row = dict(schemaVersion=1, profile=s.profile.id,
                   profileSha256=s.profile.sha256, asset=None,
                   startMs=round(started * 1000, 6), method='HEAD' if head else 'GET',
                   status=None, bodyBytesWritten=0, outcome='complete')
        with self.server.records_lock:
            self.server.next_record_id += 1
            row['requestId'] = self.server.next_record_id
        try:
            try:
                name = unquote(urlsplit(self.path).path).removeprefix('/')
            except ValueError:
                name = ''
            body = self.server.assets.get(name)
            status, start, end = 200, 0, len(body) if body is not None else 0
            if body is None:
                status = 404
            else:
                row['asset'] = name
                row['assetSha256'] = hashlib.sha256(body).hexdigest()
                try:
                    ranges = self.headers.get_all('Range', [])
                    if len(ranges) > 1:
                        raise ValueError('multiple ranges')
                    start, end = byte_range(ranges[0] if ranges else None, len(body))
                    if ranges:
                        status = 206
                except ValueError:
                    status, start, end = 416, 0, 0
            deadline = started + 120
            s.begin(deadline)
            row.update(status=status, rangeStart=start, rangeEndExclusive=end)
            self.send_response(status)
            self.send_header('Content-Length', str(end - start))
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Connection', 'close')
            self.send_header('Content-Type', 'application/dash+xml' if name.endswith('.mpd')
                             else 'application/octet-stream')
            if status == 206:
                self.send_header('Content-Range', f'bytes {start}-{end - 1}/{len(body)}')
            elif status == 416:
                self.send_header('Content-Range', f'bytes */{len(body)}')
            self.end_headers()
            if not head and status in (200, 206):
                for offset in range(start, end, 1024):
                    chunk = body[offset:min(offset + 1024, end)]
                    s.consume(len(chunk), deadline)
                    self.wfile.write(chunk)
                    row['bodyBytesWritten'] += len(chunk)
        except Disconnected:
            row['outcome'] = 'disconnected'
        except TimeoutError:
            row['outcome'] = 'timeout'
        except OSError:
            row['outcome'] = 'client_io_error'
        finally:
            row['endMs'] = round(s.elapsed() * 1000, 6)
            with self.server.records_lock:
                self.server.log.write(json.dumps(row, sort_keys=True) + '\n')
                self.server.log.flush()
            self.close_connection = True


def make_server(root, profile, log, port=0, now=time.monotonic, sleep=time.sleep):
    return FixtureServer(root, profile, log, port, now, sleep)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--profiles', type=Path,
                        default=Path(__file__).with_name('profiles.json'))
    parser.add_argument('--profile', default='down-and-recover-v1')
    parser.add_argument('--port', type=int, default=18779)
    parser.add_argument('--log', type=Path, required=True)
    args = parser.parse_args()
    profiles = load_profiles(args.profiles)
    if args.profile not in profiles:
        parser.error('unknown profile')
    with args.log.open('x') as log:
        server = make_server(args.root, profiles[args.profile], log, args.port)
        print(json.dumps(dict(url=f'http://127.0.0.1:{server.server_port}/manifest.mpd',
                              profile=args.profile,
                              profileSha256=server.shaper.profile.sha256,
                              assetCount=len(server.assets))), flush=True)
        try:
            server.serve_forever(poll_interval=.05)
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()
            print(json.dumps(dict(acceptedConnections=server.requests,
                                  rejectedConnections=server.rejected_requests,
                                  recordedRequests=server.next_record_id)), flush=True)


if __name__ == '__main__':
    main()

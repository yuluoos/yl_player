#!/usr/bin/env python3
"""Loopback HTTP fixture server with a shared, versioned shaping timeline.

Only SHA256SUMS-listed immutable fixture bytes are served. No proxying, native
player changes, global network settings, or inferred playback measurements.
"""
import argparse
import hashlib
import ipaddress
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


from contextlib import nullcontext
from server_timing import RequestTiming


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

    def consume(self, count, deadline, timing=None):
        with timing.measure('queue') if timing else nullcontext():
            while True:
                elapsed, _, _ = self.state(deadline)
                if self.lock.acquire(timeout=min(.05, deadline-elapsed)):
                    break
        try:
            with timing.measure('hold') if timing else nullcontext():
                remaining = float(count)
                while remaining > 1e-7:
                    elapsed, step, boundary = self.state(deadline)
                    rate = step['bytesPerSecond']
                    duration = min(boundary - elapsed, .05,
                                   remaining / rate if rate else math.inf)
                    if timing: timing.requested_sleep(duration)
                    with timing.measure('sleep') if timing else nullcontext():
                        self.sleep(duration)
                    # Scheduled time only: oversleep never creates burst credit.
                    remaining -= duration * rate
                self.state(deadline)
        finally:
            self.lock.release()


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


def owned_bind_host(value):
    if value is None:
        return '127.0.0.1'
    if not isinstance(value, str):
        raise ValueError('invalid owned listener')
    address = ipaddress.IPv4Address(value)
    if str(address) != value or not any(address in ipaddress.IPv4Network(net)
            for net in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')):
        raise ValueError('owned listener requires literal RFC1918 IPv4')
    return value


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = False
    # Keep the listener queue separate from the eight-handler admission limit.
    # A queue of eight triggered macOS SYN cookies in an eight-connection burst.
    request_queue_size = 32

    def __init__(self, root, profile, log, port, now, sleep, start_on_first_get, run_id, owned_host=None, connection_mode="close", connection_key=None):
        if connection_mode not in ("close", "http11-close", "http11-keepalive"):
            raise ValueError("invalid connection mode")
        self.connection_mode = connection_mode
        self.connection_key = connection_key
        self.connection_ids = {}
        self.lifecycle_origin = now()
        self.lifecycle_connections = {}
        self.lifecycle_rejections = []
        host = owned_bind_host(owned_host)
        if run_id is not None and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}', run_id):
            raise ValueError('invalid run id')
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
        self.run_id = run_id
        self.timeline_mode = 'first-get' if start_on_first_get else 'server-start'
        self.started = not start_on_first_get
        super().__init__((host, port), Handler)

    def process_request(self, request, client_address):
        with self.handlers:
            if self.active >= 8 or self.requests >= 10000:
                # Bounded threads/log; overload is not a shaped media request.
                self.rejected_requests += 1
                if len(self.lifecycle_rejections) < 32:
                    self.lifecycle_rejections.append(dict(elapsed=self.shaper.now()-self.lifecycle_origin,
                        reason='activeLimit' if self.active >= 8 else 'connectionLimit', active=self.active))
                self.shutdown_request(request)
                return
            self.active += 1
            self.requests += 1
            self.connection_ids[request] = self.requests
            self.lifecycle_connections[self.requests] = dict(connectionId=self.requests,
                acceptedSeconds=self.shaper.now()-self.lifecycle_origin, closedSeconds=None,
                activeAtAdmission=self.active, requestIds=[], unrecordedRequests=0, closeReason=None)
            if self.connection_key is not None:
                from transaction_connections import connection_token
                self.lifecycle_connections[self.requests]['connectionToken'] = connection_token(
                    self.connection_key,request.getpeername(),request.getsockname())
            self.active_sockets.add(request)
            self.handlers.notify_all()
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            with self.handlers:
                row = self.lifecycle_connections[self.connection_ids[request]]
                row['closedSeconds'] = self.shaper.now()-self.lifecycle_origin
                if row['closeReason'] is None: row['closeReason'] = 'handlerEnded'
                self.active -= 1
                self.active_sockets.discard(request)
                self.connection_ids.pop(request, None)
                self.handlers.notify_all()

    def interrupt_connection(self, connection, reason):
        with self.handlers:
            self._mark_close(connection, reason)
        interrupt_socket(connection)

    def _mark_close(self, connection, reason):
        row = self.lifecycle_connections.get(self.connection_ids.get(connection))
        if row is not None and row['closedSeconds'] is None and row['closeReason'] is None:
            row['closeReason'] = reason

    def connection_lifecycle(self):
        # Snapshot after server_close for complete evidence; no addresses/headers.
        import copy
        with self.handlers:
            return copy.deepcopy(dict(version=2 if self.connection_key is not None else 1, acceptedCount=self.requests,
                rejectedCount=self.rejected_requests,
                droppedRejections=self.rejected_requests-len(self.lifecycle_rejections),
                connections=list(self.lifecycle_connections.values()), rejections=self.lifecycle_rejections))

    def wait_handlers(self):
        with self.handlers:
            return self.handlers.wait_for(lambda: self.active == 0, timeout=5)

    def server_close(self):
        self.shaper.stopped.set()
        with self.handlers:
            for connection in self.active_sockets:
                self._mark_close(connection, 'serverShutdown')
                interrupt_socket(connection)
        super().server_close()

    def handle_error(self, request, client_address):
        # Never print incoming URLs/headers or exception text.
        with self.handlers:
            self._mark_close(request, 'handlerError')


def interrupt_socket(connection):
    try:
        connection.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'  # One request/connection, no hidden keepalive.

    def setup(self):
        self.protocol_version = "HTTP/1.0" if self.server.connection_mode == "close" else "HTTP/1.1"
        self.connection_id = self.server.connection_ids[self.request]
        self.connection_request_index = 0
        self.request.settimeout(2)
        super().setup()
        # Inactivity timeout alone does not bound a slowly trickling header.
        self.connection_timer = threading.Timer(
            self.server.connection_timeout, self.server.interrupt_connection,
            args=(self.request, 'absoluteDeadline'))
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
        # A persistent socket must not bypass the existing 10,000-record budget.
        with self.server.records_lock:
            if self.server.next_record_id >= 10000:
                with self.server.handlers:
                    self.server.lifecycle_connections[self.connection_id]['unrecordedRequests'] += 1
                    self.server._mark_close(self.request, 'requestRecordLimit')
                self.close_connection = True
                return
            self.server.next_record_id += 1
            request_id = self.server.next_record_id
        self.connection_request_index += 1
        with self.server.handlers:
            self.server.lifecycle_connections[self.connection_id]['requestIds'].append(request_id)
        s = self.server.shaper
        try:
            name = unquote(urlsplit(self.path).path).removeprefix('/')
        except ValueError:
            name = ''
        body = self.server.assets.get(name)
        with self.server.handlers:
            if not head and body is not None and not self.server.started:
                s.origin = s.now()
                self.server.started = True
            active = self.server.started
        timing = RequestTiming(s.now)
        started = s.elapsed()
        row = dict(schemaVersion=1, profile=s.profile.id,
                   connectionMode=self.server.connection_mode, connectionId=self.connection_id,
                   connectionRequestIndex=self.connection_request_index, requestId=request_id,
                   runId=self.server.run_id, timelineMode=self.server.timeline_mode,
                   timelineState='active' if active else 'pending',
                   profileSha256=s.profile.sha256, asset=None,
                   startMs=round(started * 1000, 6) if active else None,
                   method='HEAD' if head else 'GET',
                   status=None, bodyBytesWritten=0, outcome='complete',
                   phaseBoundariesMs=[step['atMs'] for step in s.profile.steps],
                   phaseBytesWritten=[0]*len(s.profile.steps))
        trace_ids = self.headers.get_all('X-Yl-Trace-Id', [])
        if len(trace_ids) == 1 and re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', trace_ids[0]):
            row['proxyTraceID'] = trace_ids[0]
        try:
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
            if active:
                with timing.measure('latency'):
                    s.begin(deadline)
            row.update(status=status, rangeStart=start, rangeEndExclusive=end)
            self.send_response(status)
            self.send_header('Content-Length', str(end - start))
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Cache-Control', 'no-store')
            persistent = self.server.connection_mode == 'http11-keepalive' and not self.close_connection
            self.send_header('Connection', 'keep-alive' if persistent else 'close')
            self.send_header('X-Yl-Timeline-Mode', self.server.timeline_mode)
            self.send_header('X-Yl-Timeline-State', 'active' if active else 'pending')
            if active:
                # Client brackets this header with its own monotonic clock.
                # It is profile time, never source-to-display latency.
                self.send_header('X-Yl-Elapsed-Us', str(round(s.elapsed() * 1_000_000)))
            self.send_header('X-Yl-Request-Id', str(row['requestId']))
            self.send_header('X-Yl-Profile-Id', s.profile.id)
            self.send_header('X-Yl-Profile-Sha256', s.profile.sha256)
            if self.server.run_id is not None:
                self.send_header('X-Yl-Run-Id', self.server.run_id)
            if body is not None:
                self.send_header('X-Yl-Asset-Sha256', row['assetSha256'])
            self.send_header('Content-Type', 'application/dash+xml' if name.endswith('.mpd')
                             else 'application/vnd.apple.mpegurl' if name.endswith('.m3u8')
                             else 'application/octet-stream')
            if status == 206:
                self.send_header('Content-Range', f'bytes {start}-{end - 1}/{len(body)}')
            elif status == 416:
                self.send_header('Content-Range', f'bytes */{len(body)}')
            with timing.measure('headerWrite'):
                self.end_headers()
            if not head and status in (200, 206):
                for offset in range(start, end, 1024):
                    chunk = body[offset:min(offset + 1024, end)]
                    s.consume(len(chunk), deadline, timing)
                    with timing.measure('bodyWrite'):
                        self.wfile.write(chunk)
                    row['bodyBytesWritten'] += len(chunk)
                    phase = max(i for i, step in enumerate(s.profile.steps)
                                if step['atMs'] <= s.elapsed()*1000)
                    row['phaseBytesWritten'][phase] += len(chunk)
        except Disconnected:
            row['outcome'] = 'disconnected'
        except TimeoutError:
            row['outcome'] = 'timeout'
        except OSError:
            row['outcome'] = 'client_io_error'
        finally:
            row['endMs'] = round(s.elapsed() * 1000, 6) if active else None
            row['serverTiming'] = timing.finish()
            with self.server.records_lock:
                self.server.log.write(json.dumps(row, sort_keys=True) + '\n')
                self.server.log.flush()
            if self.server.connection_mode != 'http11-keepalive' or row['outcome'] != 'complete':
                self.close_connection = True


def make_server(root, profile, log, port=0, now=time.monotonic, sleep=time.sleep,
                start_on_first_get=False, run_id=None, owned_host=None, connection_mode="close", connection_key=None):
    return FixtureServer(root, profile, log, port, now, sleep, start_on_first_get, run_id, owned_host, connection_mode, connection_key)


def summarize_connections(rows, expected_mode):
    def require(ok):
        if not ok: raise ValueError('invalid connection evidence')
    require(expected_mode in ('close', 'http11-close', 'http11-keepalive'))
    require(isinstance(rows,list) and 0 < len(rows) <= 10000)
    connections={}
    for row in rows:
        require(isinstance(row,dict) and row.get('connectionMode')==expected_mode)
        ident,index=row.get('connectionId'),row.get('connectionRequestIndex')
        require(type(ident) is int and 1 <= ident <= 10000 and type(index) is int and 1 <= index <= 10000)
        entries=connections.setdefault(ident,[]);entries.append(index)
    for indices in connections.values():
        require(indices==list(range(1,len(indices)+1)))
        require(expected_mode=='http11-keepalive' or len(indices)==1)
    return dict(mode=expected_mode, requests=len(rows), connectionsWithRequests=len(connections),
        reusedRequests=len(rows)-len(connections), maximumRequestsPerConnection=max(map(len,connections.values())),
        capabilityAccepted=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--profiles', type=Path,
                        default=Path(__file__).with_name('profiles.json'))
    parser.add_argument('--profile', default='down-and-recover-v1')
    parser.add_argument('--port', type=int, default=18779)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--connection-mode', choices=('close','http11-close','http11-keepalive'), default='close')
    parser.add_argument('--start-on-first-get', action='store_true')
    parser.add_argument('--run-id')
    args = parser.parse_args()
    profiles = load_profiles(args.profiles)
    if args.profile not in profiles:
        parser.error('unknown profile')
    with args.log.open('x') as log:
        server = make_server(args.root, profiles[args.profile], log, args.port,
                             start_on_first_get=args.start_on_first_get, run_id=args.run_id, connection_mode=args.connection_mode)
        print(json.dumps(dict(url=f'http://127.0.0.1:{server.server_port}/manifest.mpd',
                              profile=args.profile, connectionMode=server.connection_mode,
                              runId=server.run_id, timelineMode=server.timeline_mode,
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

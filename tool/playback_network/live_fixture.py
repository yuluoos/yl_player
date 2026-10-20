#!/usr/bin/env python3
"""Finite, owned loopback HLS/HTTP-FLV source with shared application shaping.

FFmpeg rewrites timestamps while looping the pinned source. This is transport
and public-state evidence, never a source-to-display clock or physical A/V proof.
RTMP uses the separately pinned tool/rtmp_acceptance runner.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import shutil
import signal
import subprocess
import threading
import time

from network_profile import Disconnected, Profile, Shaper, interrupt_socket, load_profiles

SOURCE_SHA256 = 'cfe009b1b03b6cacf4ae9f037eed4441a32b99508d4fabccb429bea439cf570b'
ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'tool/consumer_fixtures/apple_flutter/Resources/h264_aac.flv'


class LiveFixture:
    def __init__(self, protocol, source, output, run_id, ffmpeg, *, profile=None, port=0):
        if protocol not in {'hls', 'flv'} or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}', run_id):
            raise ValueError('invalid capture identity')
        if hashlib.sha256(Path(source).read_bytes()).hexdigest() != SOURCE_SHA256:
            raise ValueError('owned media hash mismatch')
        self.protocol, self.source, self.output = protocol, Path(source).resolve(), Path(output)
        self.run_id, self.ffmpeg = run_id, ffmpeg
        self.output.mkdir(parents=True, exist_ok=False)
        self.profile = profile or Profile({'id': 'owned-unshaped-v1', 'steps': [
            {'atMs': 0, 'bytesPerSecond': 1000000000, 'latencyMs': 0}]})
        self.shaper = Shaper(self.profile)
        self.started = False
        self.children, self.handles, self.records = [], [], []
        self.lock = threading.RLock()
        self.connections = set()
        self.total_connections = 0
        self.stopping = False
        self.receipt = None
        fixture = self

        class Server(ThreadingHTTPServer):
            daemon_threads = False
            def process_request(self, connection, address):
                with fixture.lock:
                    if fixture.stopping or len(fixture.connections) >= 8 or fixture.total_connections >= 10000:
                        self.shutdown_request(connection)
                        return
                    fixture.connections.add(connection)
                    fixture.total_connections += 1
                super().process_request(connection, address)

            def process_request_thread(self, connection, address):
                try:
                    super().process_request_thread(connection, address)
                finally:
                    with fixture.lock:
                        fixture.connections.discard(connection)

            def handle_error(self, *args):
                pass  # Never print arbitrary request URLs/headers or native errors.

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_HEAD(self):
                self.serve(head=True)
            def do_GET(self):
                self.serve(head=False)
            def serve(self, head):
                valid = (self.path == '/live.flv' if protocol == 'flv' else
                         self.path == '/live.m3u8' or bool(re.fullmatch(r'/segment[0-9]{1,7}\.ts', self.path)))
                if not valid:
                    self.send_error(404)
                    return
                self.connection.settimeout(2)
                child = None
                record = None
                try:
                    with fixture.lock:
                        if fixture.stopping:
                            return
                        if not head and not fixture.started:
                            fixture.shaper.origin = time.monotonic()
                            fixture.started = True
                        if not head:
                            if protocol == 'flv' and len(fixture.children) >= 32:
                                self.send_error(503)
                                return
                            record = {'id': len(fixture.records), 'path': self.path,
                                      'startUs': round(fixture.shaper.elapsed() * 1000000), 'bytes': 0}
                            fixture.records.append(record)
                            if protocol == 'flv':
                                child = fixture.spawn(['-f', 'flv', 'pipe:1'], pipe=True)
                    body = None
                    if protocol == 'hls':
                        path = fixture.output / self.path[1:]
                        try:
                            body = path.read_bytes()
                        except OSError:
                            self.send_error(404)
                            return
                    if not head:
                        fixture.shaper.begin(300)
                    self.send_response(200)
                    self.send_header('Content-Type', 'video/x-flv' if protocol == 'flv' else
                                     'application/vnd.apple.mpegurl' if self.path.endswith('.m3u8') else 'video/mp2t')
                    self.send_header('Cache-Control', 'no-store')
                    self.send_header('X-Yl-Run-Id', fixture.run_id)
                    self.send_header('X-Yl-Media-SHA256', SOURCE_SHA256)
                    self.send_header('X-Yl-Profile-SHA256', fixture.profile.sha256)
                    self.send_header('X-Yl-Timeline-State', 'active' if fixture.started else 'pending')
                    if body is not None:
                        self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    if head:
                        return
                    offset = 0
                    while not fixture.shaper.stopped.is_set():
                        chunk = child.stdout.read1(8192) if child else body[offset:offset + 8192]
                        if not chunk:
                            break
                        fixture.shaper.consume(len(chunk), 300)
                        self.wfile.write(chunk)
                        self.wfile.flush()
                        record['bytes'] += len(chunk)
                        offset += len(chunk)
                except (OSError, TimeoutError, Disconnected):
                    if record is not None:
                        record['interrupted'] = True
                finally:
                    if child:
                        fixture.stop_child(child)
                    if record is not None:
                        record['endUs'] = round(fixture.shaper.elapsed() * 1000000)

        self.server = Server(('127.0.0.1', port), Handler)
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def spawn(self, extra, *, pipe=False):
        # Caller holds the lock (or has not started the serving thread yet).
        handle = (self.output / f'publisher-{len(self.children)}.log').open('wb')
        self.handles.append(handle)
        child = subprocess.Popen([self.ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error',
            '-re', '-stream_loop', '-1', '-i', str(self.source), '-c', 'copy', *extra],
            stdout=subprocess.PIPE if pipe else handle, stderr=handle)
        self.children.append(child)
        return child

    @staticmethod
    def stop_child(child):
        if child.poll() is None:
            child.terminate()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=2)
        if child.stdout:
            child.stdout.close()

    def __enter__(self):
        try:
            if self.protocol == 'hls':
                child = self.spawn(['-f', 'hls', '-hls_time', '1', '-hls_list_size', '6',
                    '-hls_delete_threshold', '10', '-hls_flags', 'delete_segments+temp_file',
                    '-hls_segment_filename', str(self.output / 'segment%d.ts'), str(self.output / 'live.m3u8')])
                deadline = time.monotonic() + 15
                while not (self.output / 'live.m3u8').exists():
                    if child.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError('owned publisher did not start')
                    time.sleep(.05)
            self.thread.start()
            return self
        except BaseException:
            self.close()
            raise

    def __exit__(self, *args):
        self.close()

    def close(self):
        with self.lock:
            self.stopping = True
            self.shaper.stopped.set()
            for connection in self.connections:
                interrupt_socket(connection)
            # Terminate producers to interrupt blocking pipe reads before joining handlers.
            for child in self.children:
                if child.poll() is None:
                    child.terminate()
        if self.thread.is_alive():
            self.server.shutdown()
            self.thread.join(timeout=3)
        self.server.server_close()
        for child in self.children:
            self.stop_child(child)
        for handle in self.handles:
            handle.close()
        self.receipt = dict(schemaVersion=1, runId=self.run_id, protocol=self.protocol,
            sourceSha256=SOURCE_SHA256, profileId=self.profile.id, profileSha256=self.profile.sha256,
            requests=self.records, connections=self.total_connections,
            cleaned=not self.thread.is_alive() and not self.connections and all(p.poll() is not None for p in self.children),
            endToEndLatencyUs=None, physicalOutputVerified=False)
        (self.output / 'receipt.json').write_text(json.dumps(self.receipt, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--protocol', choices=['hls', 'flv'], required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ffmpeg', default=shutil.which('ffmpeg'))
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--profile', choices=load_profiles(Path(__file__).with_name('profiles.json')))
    args = parser.parse_args()
    if not args.ffmpeg:
        parser.error('FFmpeg is required')
    profile = load_profiles(Path(__file__).with_name('profiles.json')).get(args.profile)
    stopped = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopped.set())
    with LiveFixture(args.protocol, SOURCE, args.output, args.run_id, args.ffmpeg, profile=profile, port=args.port) as fixture:
        print(json.dumps(dict(runId=args.run_id, protocol=args.protocol, sourceSha256=SOURCE_SHA256,
            profileId=fixture.profile.id, profileSha256=fixture.profile.sha256,
            url=f'http://127.0.0.1:{fixture.port}/live.' + ('flv' if args.protocol == 'flv' else 'm3u8'))), flush=True)
        stopped.wait(timeout=300)
    return 0 if fixture.receipt['cleaned'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

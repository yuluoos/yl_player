#!/usr/bin/env python3
"""Continuous HTTP-FLV fixture with valid advancing timestamps; no FFmpeg process."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import time
import socket
import threading

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, default=18095)
parser.add_argument('--fixture', type=Path, default=Path(__file__).resolve().parents[1] / 'consumer_fixtures/apple_flutter/Resources/h264_aac.flv')
args = parser.parse_args()
data = args.fixture.read_bytes()
assert data[:3] == b'FLV'
tags, offset = [], 13
while offset + 15 <= len(data):
    size = int.from_bytes(data[offset + 1:offset + 4], 'big')
    tag = data[offset:offset + size + 15]
    assert len(tag) == size + 15
    timestamp = int.from_bytes(tag[4:7], 'big') | tag[7] << 24
    if tag[0] in (8, 9) and not (tag[0] == 9 and size >= 2 and tag[12] == 2):
        tags.append((tag, timestamp))
    offset += size + 15
span = max(timestamp for _, timestamp in tags) + 40

connections = {}
connections_lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def do_GET(self):
        if self.path == '/disconnect':
            with connections_lock:
                # Serialize with each emitted tag: no original-connection video
                # can be sent beyond this PTS bound after shutdown is requested.
                bound = (max(connections.values(), default=0) + 1000) / 1000
                current = list(connections)
                connections.clear()
                for connection in current:
                    try:
                        connection.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
            body = str(bound).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'video/x-flv')
        self.send_header('Connection', 'close')
        self.end_headers()
        with connections_lock:
            connections[self.connection] = 0
        try:
            self.wfile.write(data[:13])
            epoch = 0
            while True:
                for tag, timestamp in tags:
                    output = bytearray(tag)
                    if epoch >= 2 and output[12] == 0:
                        if self.path.startswith('/aac-change') and output[0] == 8:
                            output[13:15] = bytes([0x12, 0x08])
                        if self.path.startswith('/h264-change') and output[0] == 9:
                            output[19] = 13
                            output[27] = 13
                    current = timestamp + epoch * span
                    output[4:7] = (current & 0xffffff).to_bytes(3, 'big')
                    output[7] = current >> 24
                    with connections_lock:
                        if self.connection not in connections:
                            return
                        self.wfile.write(output)
                        if output[0] == 9 and output[12] == 1:
                            composition = int.from_bytes(output[13:16], 'big', signed=True)
                            connections[self.connection] = max(connections[self.connection], current + composition)
                self.wfile.flush()
                epoch += 1
                if epoch >= 16:
                    time.sleep(span / 1000)
        except OSError:
            pass
        finally:
            with connections_lock:
                connections.pop(self.connection, None)
            self.close_connection = True

server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
print(f'http://127.0.0.1:{server.server_port}/live.flv', flush=True)
server.serve_forever()

#!/usr/bin/env python3
"""Capture the owned example window, named simulator, or requested iPhone display.

No media/player APIs are mocked. Requires existing screen-capture permission on
macOS; never requests permission or captures a different application's window.
Physical-device mode requires an explicit device and may bind an explicit private
interface so the test app can request its own screenshots. Never use for DRM.
The bounded request count and unique output files preserve failed measurements.
"""
import argparse
import http.server
import json
import ipaddress
import re
import secrets
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--platform', choices=['macos', 'ios', 'ios-device'], required=True)
parser.add_argument('--window-helper', type=Path)
parser.add_argument('--simulator')
parser.add_argument('--device')
parser.add_argument('--bind-address', default='127.0.0.1', help='Explicit local interface for physical-device captures; never wildcard')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
assert (args.platform == 'macos' and args.window_helper) or (args.platform == 'ios' and args.simulator) or (args.platform == 'ios-device' and args.device)
address = ipaddress.ip_address(args.bind_address)
assert address.version == 4 and not address.is_unspecified and (address.is_loopback or address.is_private)
assert args.platform == 'ios-device' or address.is_loopback
args.output.mkdir(parents=True, exist_ok=True)
token = secrets.token_hex(16)
count = 0

class Capture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global count
        if self.path != '/' + token or count >= 256:
            self.send_error(404)
            return
        count += 1
        target = args.output / f'{count:03d}.png'
        try:
            if args.platform == 'macos':
                window = subprocess.check_output([str(args.window_helper.resolve())], text=True, timeout=5).strip()
                if not re.fullmatch(r'[0-9]+', window):
                    raise ValueError('No unique owned window')
                command = ['/usr/sbin/screencapture', '-x', '-o', '-l', window, '-t', 'png', str(target)]
            elif args.platform == 'ios-device':
                command = ['xcrun', 'devicectl', 'device', 'capture', 'screenshot', '--device', args.device, '--destination', str(target), '--timeout', '8']
            else:
                command = ['xcrun', 'simctl', 'io', args.simulator, 'screenshot', '--type=png', '--mask=black', str(target)]
            subprocess.run(command, check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            payload = target.read_bytes()
            if not 0 < len(payload) <= 16 * 1024 * 1024:
                raise ValueError('Capture exceeds bound')
            self.send_response(200)
            self.send_header('Content-Type', 'image/png')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            print(json.dumps({'capture': count, 'bytes': len(payload), 'path': str(target)}), flush=True)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            print(json.dumps({"capture": count, "error": type(error).__name__, "returncode": getattr(error, "returncode", None)}), flush=True)
            self.send_error(500, 'Owned test capture failed')
    def log_message(self, *unused):
        pass

server = http.server.HTTPServer((args.bind_address, 0), Capture)
print(json.dumps({'captureUrl': f'http://{args.bind_address}:{server.server_port}/{token}'}), flush=True)
server.serve_forever()

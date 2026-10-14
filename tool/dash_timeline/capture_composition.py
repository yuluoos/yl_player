#!/usr/bin/env python3
"""Loopback-only capture of the owned P01 example window or named iOS Simulator.

No media/player APIs are mocked. Requires existing screen-capture permission on
macOS; never requests permission or captures a different application's window.
The bounded request count and unique output files preserve failed measurements.
"""
import argparse
import http.server
import json
import re
import secrets
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--platform', choices=['macos', 'ios'], required=True)
parser.add_argument('--window-helper', type=Path)
parser.add_argument('--simulator')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
assert (args.platform == 'macos' and args.window_helper) or (args.platform == 'ios' and args.simulator)
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

server = http.server.HTTPServer(('127.0.0.1', 0), Capture)
print(json.dumps({'captureUrl': f'http://127.0.0.1:{server.server_port}/{token}'}), flush=True)
server.serve_forever()

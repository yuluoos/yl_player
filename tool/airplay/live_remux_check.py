#!/usr/bin/env python3
"""Compile production Apple sources and play a continuous HTTP-FLV/RTMP fixture."""
from pathlib import Path
import argparse
import platform
import subprocess
import shutil
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('urls', nargs='+')
parser.add_argument('--output', type=Path)
parser.add_argument('--reconnect', action='store_true')
parser.add_argument('--expect-config-error', action='store_true')
parser.add_argument('--flutter-sdk', type=Path, default=Path.home() / 'flutter')
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
package = root / 'packages/yl_player_apple/darwin/yl_player_apple'
flutter = args.flutter_sdk / 'bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64'
bridge = package / 'Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64'
with tempfile.TemporaryDirectory(prefix='yl-airplay-live-') as scratch:
    output = args.output or Path(scratch) / 'live-check'
    cmd = ['xcrun', 'swiftc', '-emit-executable', '-swift-version', '5', '-module-name', 'yl_player_apple',
           '-target', f'{platform.machine()}-apple-macos12.0', '-module-cache-path', '/tmp/yl-airplay-live-modules']
    for directory in (flutter, bridge):
        cmd += ['-F', str(directory), '-Xlinker', '-rpath', '-Xlinker', str(directory)]
    sources = Path(scratch) / 'Sources'
    shutil.copytree(package / 'Sources/yl_player_apple', sources)
    cmd += [str(path) for path in sorted(sources.rglob('*.swift'))]
    cmd += [str(Path(__file__).with_name('live_remux_test.swift')), '-o', str(output)]
    subprocess.run(cmd, check=True)
    for url in args.urls:
        subprocess.run([str(output), url] + (["--reconnect"] if args.reconnect else []) + (["--expect-config-error"] if args.expect_config_error else []), check=True)

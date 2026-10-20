#!/usr/bin/env python3
"""Build independent core/delivery modules and decode live HTTP-FLV/RTMP HLS."""
from pathlib import Path
import argparse
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tool.media_delivery.native_build import build_modules

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('urls', nargs='+')
parser.add_argument('--output', type=Path)
parser.add_argument('--build-dir', type=Path, default=Path('/tmp/yl-airplay-native-modules'))
parser.add_argument('--reconnect', action='store_true')
parser.add_argument('--expect-config-error', action='store_true')
parser.add_argument('--flutter-sdk', type=Path)
args = parser.parse_args()
if args.flutter_sdk:
    os.environ['FLUTTER_ROOT'] = str(args.flutter_sdk)
build = build_modules(args.build_dir)
output = build.compile_test([Path(__file__).with_name('live_remux_test.swift')],
                            args.output or args.build_dir / 'live-check')
for url in args.urls:
    subprocess.run([str(output), url] + (['--reconnect'] if args.reconnect else []) +
                   (['--expect-config-error'] if args.expect_config_error else []), check=True)

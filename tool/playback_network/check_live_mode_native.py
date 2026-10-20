#!/usr/bin/env python3
"""Compile Apple production sources and execute device-free P04 policy checks.

Requires macOS/Xcode, an already cached Flutter macOS engine, and the repository's
FFmpeg framework. Does not launch Flutter, an emulator, or a media source.
"""
import argparse
import os
import sys
from pathlib import Path
import platform
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter-sdk', required=True, type=Path)
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('Apple native checks require macOS')
    root = Path(__file__).resolve().parents[2]
    sys.path.insert(0, str(root))
    from tool.media_delivery.native_build import build_modules
    os.environ['FLUTTER_ROOT'] = str(args.flutter_sdk.resolve())
    with tempfile.TemporaryDirectory(prefix='yl-live-native-') as scratch:
        output = Path(scratch) / 'live-native-check'
        native = build_modules(Path(scratch) / 'native', include_apple=True, include_delivery=False)
        native.compile_test([Path(__file__).with_name('live_mode_native_test.swift')], output,
                            imports=['yl_player_media_core', 'yl_player_apple'])
        subprocess.run([str(output)], check=True)



if __name__ == '__main__':
    main()

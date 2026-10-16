#!/usr/bin/env python3
"""Compile Apple production sources and execute device-free P04 policy checks.

Requires macOS/Xcode, an already cached Flutter macOS engine, and the repository's
FFmpeg framework. Does not launch Flutter, an emulator, or a media source.
"""
import argparse
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
    package = root / 'packages/yl_player_apple/darwin/yl_player_apple'
    flutter = args.flutter_sdk.resolve() / 'bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64'
    bridge = package / 'Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64'
    for framework in (flutter / 'FlutterMacOS.framework', bridge / 'YlFFmpegBridge.framework'):
        if not framework.is_dir():
            parser.error(f'Required framework is unavailable: {framework}')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='yl-live-native-') as scratch:
        output = Path(scratch) / 'live-native-check'
        command = ['xcrun', 'swiftc', '-emit-executable', '-module-name', 'yl_player_apple',
                   '-target', f'{platform.machine()}-apple-macos12.0', '-sdk', sdk,
                   '-module-cache-path', str(Path(scratch) / 'modules')]
        for directory in (flutter, bridge):
            command += ['-F', str(directory), '-Xlinker', '-rpath', '-Xlinker', str(directory)]
        command += [str(path) for path in sorted((package / 'Sources/yl_player_apple').rglob('*.swift'))]
        command += [str(Path(__file__).with_name('live_mode_native_test.swift')), '-o', str(output)]
        subprocess.run(command, check=True)
        subprocess.run([str(output)], check=True)


if __name__ == '__main__':
    main()

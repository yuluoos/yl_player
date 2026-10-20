#!/usr/bin/env python3
"""编译生产 Apple 源码并验证独立媒体交付租约生命周期。"""
from pathlib import Path
import platform
import subprocess
import tempfile
import sys
import shutil
root = Path(__file__).resolve().parents[2]
package = root / 'packages/yl_player_apple/darwin/yl_player_apple'
frameworks = [Path.home() / 'flutter/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64', package / 'Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64']
with tempfile.TemporaryDirectory(prefix='yl-delivery-') as scratch:
    output = Path(scratch) / 'delivery-tests'
    cmd = ['xcrun', 'swiftc', '-emit-executable', '-whole-module-optimization', '-Onone', '-swift-version', '5', '-module-name', 'yl_player_apple', '-target', f'{platform.machine()}-apple-macos12.0', '-module-cache-path', '/tmp/yl-airplay-live-modules']
    for directory in frameworks:
        cmd += ['-F', str(directory), '-Xlinker', '-rpath', '-Xlinker', str(directory)]
    sources = Path(scratch) / 'Sources'
    shutil.copytree(package / 'Sources/yl_player_apple', sources)
    cmd += [str(path) for path in sorted(sources.rglob('*.swift'))]
    cmd += [str(Path(__file__).with_name('media_delivery_test.swift')), '-o', str(output)]
    subprocess.run(cmd, check=True)
    subprocess.run([str(output), *sys.argv[1:]], check=True)

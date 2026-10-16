#!/usr/bin/env python3
"""Host-only production error-envelope checks; never creates a player or GPU."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile


def main():
    if sys.platform != 'darwin':
        print('FEL envelope checks require macOS and the Flutter macOS framework')
        return 77
    root = Path(__file__).resolve().parents[2]
    flutter = shutil.which('flutter')
    flutter_root = os.environ.get('FLUTTER_ROOT')
    if flutter_root:
        sdk = Path(flutter_root)
    elif flutter:
        sdk = Path(flutter).resolve().parents[1]
    else:
        print('FEL envelope checks require an installed Flutter SDK')
        return 77
    framework = sdk / 'bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64'
    if not (framework / 'FlutterMacOS.framework').is_dir():
        print('FEL envelope checks require the cached Flutter macOS framework')
        return 77
    package = root / 'packages/yl_player_apple/darwin/yl_player_apple'
    bridge = package / 'Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64'
    sources = package / 'Sources/yl_player_apple'
    files = ['Shared/VideoToolbox/YlFELFailure.swift', 'Shared/VideoToolbox/YlFELMetadata.swift',
             'Shared/Dependencies/NativePlayerError.swift', 'Shared/Diagnostics/YlAppleSafeDiagnostics.swift',
             'Shared/Diagnostics/YlAppleFailureMapper.swift', 'Shared/DRM/YlFairPlayFailure.swift',
             'Generated/YlPlayerApple.g.swift']
    with tempfile.TemporaryDirectory(prefix='yl-fel-failure-') as temp:
        scratch = Path(temp)
        cmd = ['xcrun', 'swiftc', '-module-cache-path', str(scratch / 'modules'),
               '-F', str(framework), '-F', str(bridge),
               '-Xlinker', '-rpath', '-Xlinker', str(framework),
               '-Xlinker', '-rpath', '-Xlinker', str(bridge),
               *(str(sources / name) for name in files),
               str(root / 'tool/apple_fel/metadata_fixture.swift'),
               str(root / 'tool/apple_fel/failure_tests.swift'), '-o', str(scratch / 'tests')]
        subprocess.run(cmd, check=True, timeout=180)
        return subprocess.run([str(scratch / 'tests')], timeout=30).returncode


if __name__ == '__main__':
    raise SystemExit(main())

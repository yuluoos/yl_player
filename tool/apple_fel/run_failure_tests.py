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
    sys.path.insert(0, str(root))
    from tool.media_delivery.native_build import build_modules
    os.environ['FLUTTER_ROOT'] = str(sdk)
    sources = package / 'Sources/yl_player_apple'
    files = ['Shared/VideoToolbox/YlFELFailure.swift', 'Shared/VideoToolbox/YlFELMetadata.swift',
             'Shared/Diagnostics/YlAppleSafeDiagnostics.swift',
             'Shared/Diagnostics/YlAppleFailureMapper.swift', 'Shared/DRM/YlFairPlayFailure.swift',
             'Generated/YlPlayerApple.g.swift']
    with tempfile.TemporaryDirectory(prefix='yl-fel-failure-') as temp:
        scratch = Path(temp)
        native = build_modules(scratch / 'native', include_delivery=False)
        native.compile_test([*(sources / name for name in files),
            root / 'tool/apple_fel/metadata_fixture.swift',
            root / 'tool/apple_fel/failure_tests.swift'], scratch / 'tests',
            imports=['yl_player_media_core'])
        return subprocess.run([str(scratch / 'tests')], timeout=30).returncode


if __name__ == '__main__':
    raise SystemExit(main())

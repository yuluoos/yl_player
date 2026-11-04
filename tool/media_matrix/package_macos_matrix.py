"""Bind a Debug matrix frontend to the optimized SDK used for AV1 qualification."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from bound_artifacts import sha_file

ROOT = Path(__file__).resolve().parents[2]
FRAMEWORKS = ('yl-player-apple', 'YlFFmpegBridge')
ENTITLEMENTS = ROOT / 'packages/yl_player/example/macos/Runner/DebugProfile.entitlements'


def run(*args):
    subprocess.run(args, check=True)


def sdk_identity(frameworks):
    return ':'.join(sha_file(frameworks / (name + '.framework') / name) for name in FRAMEWORKS)


def remove_build_paths(binary):
    commands = subprocess.check_output(['otool', '-l', binary], text=True)
    paths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', commands)
    build_paths = [p for p in paths if Path(p).is_absolute() and Path(p).name == 'PackageFrameworks']
    for path in build_paths:
        run('install_name_tool', '-delete_rpath', path, binary)
    return bool(build_paths)


def package(debug_app, capture_app, output, profile):
    if output.exists():
        raise FileExistsError(output)
    run('codesign', '--verify', '--deep', '--strict', capture_app)
    frozen = capture_app / 'Contents/Frameworks'
    identity = sdk_identity(frozen)
    if profile and json.loads(profile.read_bytes())['key']['decoderBuild'] != identity:
        raise ValueError('Profile does not identify the captured SDK and codec')
    with tempfile.TemporaryDirectory(dir=output.parent) as staging:
        app = Path(staging) / output.name
        shutil.copytree(debug_app, app, symlinks=True)
        frameworks = app / 'Contents/Frameworks'
        for name in FRAMEWORKS:
            target = frameworks / (name + '.framework')
            shutil.rmtree(target)
            shutil.copytree(frozen / target.name, target, symlinks=True)

        # Xcode places an absolute DerivedData directory before the embedded
        # frameworks. Remove it only from the Debug host and its package wrappers.
        for binary in (app / 'Contents/MacOS').iterdir():
            if remove_build_paths(binary) and binary.suffix == '.dylib':
                run('codesign', '--force', '--sign', '-', binary)
        for framework in frameworks.glob('*.framework'):
            if framework.stem in FRAMEWORKS:
                continue
            if framework.stem.endswith('_PackageProduct'):
                remove_build_paths(framework / framework.stem)
            run('codesign', '--force', '--sign', '-', framework)
        if profile:
            shutil.copyfile(profile, app / 'Contents/Resources/yl-player-qualified-av1.json')
        run('codesign', '--force', '--sign', '-', '--entitlements', ENTITLEMENTS, app)
        run('codesign', '--verify', '--deep', '--strict', app)
        app.rename(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ('debug_app', 'capture_app', 'output'):
        parser.add_argument(arg, type=Path)
    parser.add_argument('--profile', type=Path, help='Issued profile; omit only for observation preflight')
    args = parser.parse_args()
    package(args.debug_app, args.capture_app, args.output, args.profile)

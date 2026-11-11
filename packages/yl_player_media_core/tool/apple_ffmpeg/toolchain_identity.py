"""Identify cross-build tools by bytes and explicit target, not host location."""
import hashlib
import os
from pathlib import Path
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def developer_relative(path, developer):
    # Reject tools outside the selected Xcode instead of silently normalizing
    # unrelated installations to the same identity.
    return '$DEVELOPER_DIR/' + Path(path).resolve().relative_to(developer.resolve()).as_posix()


def capture():
    developer = Path(os.environ.get('DEVELOPER_DIR') or run('xcode-select', '-p'))
    target = 'arm64-apple-macos12.0'
    compiler = run('xcrun', 'clang', '--target=' + target, '--version').splitlines()
    compiler = [
        'InstalledDir: ' + developer_relative(line.removeprefix('InstalledDir: '), developer)
        if line.startswith('InstalledDir: ') else line
        for line in compiler
    ]
    result = dict(identityFormat=2, compilerVersionTarget=target,
                  xcode=run('xcodebuild', '-version'), clang='\n'.join(compiler),
                  meson=run('meson', '--version'), ninja=run('ninja', '--version'))
    for name in ('clang', 'ld', 'ar', 'ranlib'):
        path = Path(run('xcrun', '--find', name))
        result[name + '_path'] = developer_relative(path, developer)
        result[name + '_sha256'] = sha(path)
    for sdk in ('iphoneos', 'iphonesimulator', 'macosx'):
        path = Path(run('xcrun', '--sdk', sdk, '--show-sdk-path'))
        result[sdk] = dict(path=developer_relative(path, developer),
                          version=run('xcrun', '--sdk', sdk, '--show-sdk-version'),
                          build=run('xcrun', '--sdk', sdk, '--show-sdk-build-version'),
                          settings_sha256=sha(path / 'SDKSettings.json'))
    return result


if __name__ == '__main__':
    import json
    print(json.dumps(capture(), indent=2, sort_keys=True))

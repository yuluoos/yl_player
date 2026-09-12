#!/usr/bin/env python3
"""Verify the accepted immutable artifact without assuming the builder's host.

The original self-hashed build_xcframework.sh remains the reproduction recipe.
No build, lock write, or current-machine toolchain comparison occurs here.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request

ACCEPTED_LOCK_SHA256 = '4aa7e71fd455a810621a08a83d8896556112f32c9c5cde394a502628bac5acbc'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, reason):
    if not condition:
        raise SystemExit(reason)


def verify():
    script = Path(__file__).resolve().parent
    package = script.parent.parent
    lock = script / 'bridge-artifact.lock'
    # Pin the accepted provenance itself, including recorded builder identity.
    # A future accepted artifact needs an explicit provenance update here.
    require(sha(lock) == ACCEPTED_LOCK_SHA256, 'accepted provenance mismatch')
    expected = json.loads(lock.read_text())
    for relative, digest in expected['inputs'].items():
        path = package / relative
        require(path.is_file() and sha(path) == digest, f'input mismatch: {relative}')
    contract = subprocess.check_output(
        ['bash', str(script / 'build_xcframework.sh'), '--print-contract'], text=True).splitlines()
    require(contract == expected['configure_contract'], 'configuration mismatch')
    artifact = package / 'darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework'
    files = {}
    for path in sorted(artifact.rglob('*')):
        relative = path.relative_to(artifact).as_posix()
        if path.is_symlink():
            files[relative] = {'symlink': os.readlink(path)}
        elif path.is_file():
            files[relative] = {'sha256': sha(path), 'size': path.stat().st_size}
    require(files == expected['files'], 'artifact mismatch')
    pins = dict(line.split('=', 1) for line in (script / 'ffmpeg-9.0.1.lock').read_text().splitlines())
    with tempfile.TemporaryDirectory(prefix='yl-apple-verify-') as temporary:
        work = Path(temporary)
        archive, signature = work / 'source.tar.xz', work / 'source.tar.xz.asc'
        for target, variable, url in (
            (archive, 'YL_FFMPEG_ARCHIVE', pins['FFMPEG_URL']),
            (signature, 'YL_FFMPEG_SIGNATURE', pins['FFMPEG_SIGNATURE_URL']),
        ):
            if os.environ.get(variable):
                target.write_bytes(Path(os.environ[variable]).read_bytes())
            else:
                urllib.request.urlretrieve(url, target)
        require(sha(archive) == pins['FFMPEG_SHA256'], 'source archive mismatch')
        require(sha(signature) == expected['signed_source']['signature_sha256'], 'source signature mismatch')
        key = script / 'FFMPEG_RELEASE_KEY.asc'
        require(sha(key) == pins['FFMPEG_SIGNING_KEY_SHA256'], 'signing key mismatch')
        home = work / 'gnupg'
        home.mkdir(mode=0o700)
        env = dict(os.environ, GNUPGHOME=str(home))
        subprocess.run(['gpg', '--batch', '--no-autostart', '--quiet', '--import', str(key)], env=env, check=True)
        status = subprocess.check_output(
            ['gpg', '--batch', '--no-autostart', '--status-fd', '1', '--verify', str(signature), str(archive)],
            env=env, text=True)
        valid = [line.split()[2:] for line in status.splitlines() if line.startswith('[GNUPG:] VALIDSIG ')]
        fingerprint = pins['FFMPEG_SIGNING_KEY_FINGERPRINT']
        require(len(valid) == 1 and (valid[0][0] == fingerprint or valid[0][-1] == fingerprint),
                'source signature fingerprint mismatch')
        receipt = {'archive_sha256': sha(archive), 'signature_sha256': sha(signature), 'validsig': valid[0]}
        require(receipt == expected['signed_source'], 'signed source mismatch')
    print(f'Verified {len(files)} canonical file/symlink entries, all recipe/configuration inputs, accepted builder provenance and signed source; lock unchanged.')


if __name__ == '__main__':
    verify()

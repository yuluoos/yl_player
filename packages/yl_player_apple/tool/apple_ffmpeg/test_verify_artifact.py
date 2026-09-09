"""Actual verifier foreign-host and corruption discriminators; no source build."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

script = Path(__file__).resolve().parent
package = script.parent.parent
with tempfile.TemporaryDirectory(prefix='yl-foreign-verifier-') as temporary:
    root = Path(temporary)
    foreign = root / 'bin'
    foreign.mkdir()
    xcode = foreign / 'xcodebuild'
    xcode.write_text('#!/bin/sh\necho "Xcode foreign verifier host"\n')
    xcode.chmod(0o755)
    env = dict(os.environ, PATH=str(foreign) + ':' + os.environ['PATH'])
    # Fetch each pinned source input at most once per discriminator invocation.
    for variable, suffix in [('YL_FFMPEG_ARCHIVE', ''), ('YL_FFMPEG_SIGNATURE', '.asc')]:
        if not env.get(variable):
            source = root / ('ffmpeg-9.0.1.tar.xz' + suffix)
            urllib.request.urlretrieve('https://ffmpeg.org/releases/' + source.name, source)
            env[variable] = str(source)
    copy = root / 'packages/yl_player_apple'
    shutil.copytree(package, copy, symlinks=True)
    copied = copy / 'tool/apple_ffmpeg'
    lock = copied / 'bridge-artifact.lock'
    before = lock.read_bytes()

    def run(command, reason=None):
        result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(f'{command[-1]} exit={result.returncode}\n{result.stdout}', flush=True)
        if reason is None:
            assert result.returncode == 0, result.stdout
        else:
            assert result.returncode != 0 and reason in result.stdout, (reason, result.stdout)
        assert lock.read_bytes() == before, 'verification modified accepted provenance'

    verify = ['python3', str(copied / 'verify_artifact.py')]
    run(verify)
    run(['sh', str(copied / 'test_build_contract.sh')])
    # Exact-host reproducibility must reject before compiling/downloading.
    run(['sh', str(copied / 'build_xcframework.sh'), '--rebuild-check'], 'toolchain mismatch')
    mutations = [
        ('darwin/native/YlFFmpegBridge/YlFFmpegBridge.m', 'input mismatch'),
        ('tool/apple_ffmpeg/build_xcframework.sh', 'input mismatch'),
        ('tool/apple_ffmpeg/ffmpeg-9.0.1.lock', 'input mismatch'),
        ('tool/apple_ffmpeg/FFMPEG_RELEASE_KEY.asc', 'input mismatch'),
        ('darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework/ios-arm64/YlFFmpegBridge.framework/YlFFmpegBridge', 'artifact mismatch'),
    ]
    for relative, reason in mutations:
        path = copy / relative
        original = path.read_bytes()
        path.write_bytes(original + b'corruption')
        run(verify, reason)
        path.write_bytes(original)
    link = copy / 'darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64/YlFFmpegBridge.framework/Versions/Current'
    original = os.readlink(link)
    link.unlink()
    link.symlink_to('wrong')
    run(verify, 'artifact mismatch')
    link.unlink()
    link.symlink_to(original)
    for variable, reason in [('YL_FFMPEG_ARCHIVE', 'source archive mismatch'), ('YL_FFMPEG_SIGNATURE', 'source signature mismatch')]:
        bad = root / variable
        bad.write_bytes(b'corruption')
        previous = env.get(variable)
        env[variable] = str(bad)
        run(verify, reason)
        if previous is None:
            del env[variable]
        else:
            env[variable] = previous
    # Provenance mutation is rejected even if a caller changes hashes to bless bytes.
    changed = before.replace(b'Xcode 26.6', b'Xcode 00.0')
    assert changed != before
    lock.write_bytes(changed)
    result = subprocess.run(verify, env=env, text=True, capture_output=True)
    assert result.returncode != 0 and 'accepted provenance mismatch' in result.stderr
    assert lock.read_bytes() == changed
    lock.write_bytes(before)
    print('PASS: intact artifact on foreign verifier host; 9 intended-reason mutation negatives; incompatible reproduction host rejected; lock unchanged.')

"""Build the research inspector from verified local archives, without downloads."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

PIN = '614c816b6446dcd1dbaf433403d499a6026fbb5a'
ARCHIVE_SHA = '23e6e0b8262f03ed999d0170a304eac5ba544ea5a5497adf2db7b33026d957c1'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probes', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    probes = args.probes.resolve(strict=True)
    archive = probes / 'dovi_tool.tar.gz'
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA:
        raise SystemExit('Pinned source archive does not match.')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    with tarfile.open(archive) as source:
        source.extractall(output, filter='data')
    shutil.copytree(Path(__file__).parent/'stream_inspector', output/'inspector')
    env = os.environ.copy()
    env['CARGO_HOME'] = str(probes/'cargo-home')
    env['RUSTC'] = str(probes/'rust-sysroot/bin/rustc')
    env['CARGO_TARGET_DIR'] = str(output/'target')
    for command in ['test', 'build']:
        with (output/(command+'.log')).open('w') as log:
            result = subprocess.run(['cargo', command, '--locked', '--offline',
                '--manifest-path',str(output/'inspector/Cargo.toml'), '--release'],
                env=env, stdout=log, stderr=subprocess.STDOUT, timeout=300)
        if result.returncode:
            raise SystemExit(f'Inspector {command} failed; inspect {output/(command+".log")}')
    binary = output/'target/release/yl-dovi-stream-inspector'
    print(json.dumps({'binary':str(binary),
                      'sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
                      'libdovi_commit':PIN}))


if __name__ == '__main__':
    main()

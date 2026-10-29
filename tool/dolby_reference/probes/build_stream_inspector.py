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
    parser.add_argument('--compressed-cm4', action='store_true', help='Apply the hash-checked research-only compressed CM4 overlay.')
    args = parser.parse_args()
    probes = args.probes.resolve(strict=True)
    archive = probes / 'dovi_tool.tar.gz'
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA:
        raise SystemExit('Pinned source archive does not match.')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    with tarfile.open(archive) as source:
        source.extractall(output, filter='data')
    overlay_files = {}
    overlay_sha = None
    if args.compressed_cm4:
        from apply_cm4_overlay import apply
        overlay_sha = hashlib.sha256(Path(__file__).with_name('compressed_cm4_overlay.json').read_bytes()).hexdigest()
        overlay_files = apply(output / ('dovi_tool-' + PIN))
    shutil.copytree(Path(__file__).parent/'stream_inspector', output/'inspector')
    env = os.environ.copy()
    env['CARGO_HOME'] = str(probes/'cargo-home')
    env['RUSTC'] = str(probes/'rust-sysroot/bin/rustc')
    env['CARGO_TARGET_DIR'] = str(output/'target')
    env['YL_TEST_COMPRESSED_CM4'] = '1' if args.compressed_cm4 else '0'
    for command in ['test', 'build']:
        with (output/(command+'.log')).open('w') as log:
            result = subprocess.run(['cargo', command, '--locked', '--offline',
                '--manifest-path',str(output/'inspector/Cargo.toml'), '--release'],
                env=env, stdout=log, stderr=subprocess.STDOUT, timeout=300)
        if result.returncode:
            raise SystemExit(f'Inspector {command} failed; inspect {output/(command+".log")}')
    binary = output/'target/release/yl-dovi-stream-inspector'
    receipt = dict(binary=str(binary), sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                   libdovi_commit=PIN, archive_sha256=ARCHIVE_SHA,
                   parser_variant='compressed_cm4_research' if args.compressed_cm4 else 'upstream',
                   overlay_sha256=overlay_sha, overlay_files=overlay_files)
    (output/'build-receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps(receipt))


if __name__ == '__main__':
    main()

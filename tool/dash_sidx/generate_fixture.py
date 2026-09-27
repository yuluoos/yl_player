#!/usr/bin/env python3
"""Wrap repository-owned AVC fragments with an explicit flat global sidx.

Media samples are copied byte-for-byte; version 1 differs only in sidx field widths.
"""
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[2]

def main():
    origin = ROOT/'packages/yl_player/example/assets/test_media/dash/period0'
    destination = ROOT/'tool/consumer_fixtures/apple_flutter/Resources'
    initialization = (origin/'init-0.m4s').read_bytes()
    fragments = [(origin/f'chunk-0-{i:05}.m4s').read_bytes() for i in range(1,5)]
    metadata = []
    hashes = []
    for version in (0,1):
        body = struct.pack('>III', version << 24, 1, 12288)
        body += struct.pack('>II' if version == 0 else '>QQ', 0, 0)
        body += struct.pack('>HH', 0, 4)
        for fragment in fragments:
            body += struct.pack('>III', len(fragment), 12288, 0x90000000)
        index = struct.pack('>I4s', len(body)+8, b'sidx') + body
        data = initialization + index + b''.join(fragments)
        path = destination/f'dash-sidx-v{version}.mp4'
        path.write_bytes(data)
        hashes.append(f'{hashlib.sha256(data).hexdigest()}  {path.relative_to(ROOT)}')
        cursor = len(initialization)+len(index)
        references = []
        for fragment in fragments:
            references.append(dict(offset=cursor,length=len(fragment),durationTicks=12288,
                                   startsWithSAP=True,sapType=1,sapDeltaTicks=0))
            cursor += len(fragment)
        metadata.append(dict(file=path.name,version=version,indexStart=len(initialization),
            indexEndExclusive=len(initialization)+len(index),timescale=12288,
            earliestPresentationTimeTicks=0,firstOffset=0,referenceID=1,references=references))
    (ROOT/'tool/dash_sidx/SHA256SUMS').write_text('\n'.join(hashes)+'\n')
    (ROOT/'tool/dash_sidx/fixtures.json').write_text(json.dumps(metadata,indent=2)+'\n')

if __name__ == '__main__': main()

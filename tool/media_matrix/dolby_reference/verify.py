"""Compare the qualified macOS Dolby bridge and its frozen public PCM to OxideAV."""
import argparse
import array
import base64
import ctypes as c
from fractions import Fraction
import json
import lzma
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_dolby_bridge import ROOT, load_bridge
from independent_pcm import compare, read_packets, sha

CASES = [('mkv-avc-ac3-51', 'ac3', 6, 6, 0x60f), ('mkv-avc-eac3', 'eac3', 7, 2, 3)]
RATE = 48000
PACKET_FRAMES = 1536
LIMIT = 0.0002  # Existing complete-stream Dolby bridge gate.


def bridge_pcm(lib, codec_id, channels, mask, packets):
    decoder = lib.ylf_dolby_create(codec_id, RATE, channels, mask)
    assert decoder
    output = (c.c_float * (PACKET_FRAMES * channels))()
    count = c.c_int32()
    pcm = array.array('f')
    try:
        for packet in packets:
            status = lib.ylf_dolby_decode(decoder, packet, len(packet), output, PACKET_FRAMES, c.byref(count))
            assert status == 0
            assert count.value == PACKET_FRAMES
            pcm.frombytes(bytes(output))
    finally:
        lib.ylf_dolby_free(decoder)
    return pcm


def verify(args):
    matrix = json.loads((args.matrix / 'matrix-result.json').read_bytes())
    assert matrix['formatScopeAcceptance'] and matrix['supportedRows'] == 40
    records = json.loads(lzma.decompress((args.matrix / 'records.json.xz').read_bytes()))
    bridge_hash = sha(args.bridge.read_bytes())
    lib = load_bridge(args.bridge)
    cases = []
    for case_id, codec, codec_id, channels, mask in CASES:
        path = ROOT / 'packages/yl_player/example/assets/test_media/format_matrix' / (case_id + '.mkv')
        timestamps, packets = read_packets(path)
        first = timestamps[0]
        assert len(packets) == 125
        assert all((pts - first) * RATE == i * PACKET_FRAMES for i, pts in enumerate(timestamps))
        with tempfile.TemporaryDirectory() as tmp:
            payload = Path(tmp) / 'packets'
            payload.write_bytes(b''.join(struct.pack('>I', len(p)) + p for p in packets))
            reference = array.array('h', subprocess.check_output([args.reference, codec, payload]))
        actual = bridge_pcm(lib, codec_id, channels, mask, packets)
        assert len(actual) == len(reference) == 192000 * channels
        peaks = compare(actual, reference, 0, channels, 32768, LIMIT)
        windows = []
        for record in records:
            cell = record['cell']
            if cell['caseId'] != case_id:
                continue
            assert cell['mediaHash'] == sha(path.read_bytes())
            row, = record['rows']
            assert row['buildSha256'] == matrix['buildSha256']
            assert {x['image']: x['sha256'] for x in row['loadedImages']}['YlFFmpegBridge'] == bridge_hash
            for phase in row['phases']:
                for window in phase['pcmWindows']:
                    raw = base64.b64decode(window['pcmF32LE'], validate=True)
                    assert sha(raw) == window['pcmSha256'] and window['channels'] == channels
                    assert window['frames'] == 8192 and window['rate'] == RATE and len(raw) == 8192 * channels * 4
                    start = (Fraction(window['startUs'], 1000000) - first) * RATE
                    assert start.denominator == 1
                    error = compare(array.array('f', raw), reference, int(start), channels, 32768, LIMIT)
                    windows.append(dict(transport=cell['transport'], phase=phase['phase'], marker=window['marker'],
                                        startFrame=int(start), frames=8192, peakByChannel=error))
        phases = [('play', i) for i in range(4)] + [('seek-1250', 1), ('seek-2250', 2), ('seek-0', 0)]
        assert [(w['transport'], w['phase'], w['marker']) for w in windows] == [
            (transport, phase, marker) for transport in ('file', 'http') for phase, marker in phases]
        cases.append(dict(caseId=case_id, mediaSha256=sha(path.read_bytes()), packetCount=len(packets),
                          firstPacketPtsUs=int(first * 1000000), channels=channels, frames=192000,
                          bridgeFloat32Sha256=sha(actual.tobytes()), referenceS16Sha256=sha(reference.tobytes()),
                          peakByChannel=peaks, publicWindows=windows))
    return dict(matrixId=matrix['matrixId'], buildSha256=matrix['buildSha256'], bridgeSha256=bridge_hash,
                referenceBinarySha256=sha(args.reference.read_bytes()), peakLimit=LIMIT, cases=cases)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('bridge', 'reference', 'matrix', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    if not __debug__:
        parser.error('PCM verification requires Python assertions enabled')
    result = verify(args)
    with args.output.open('x') as out:
        json.dump(result, out, indent=2, allow_nan=False)
        out.write('\n')

"""Verify the owned DTS Core stereo stream and same-build public PCM windows."""
import argparse
import array
import base64
import ctypes as c
import json
import lzma
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from independent_pcm import compare, read_packets, sha

CASE = 'mkv-avc-dts'
ROOT = Path(__file__).resolve().parents[3]
RATE = 48000
FRAMES = 512  # Per compressed packet in this fixture.
CHANNELS = 2
SCALE = 2**31  # Interleaved signed S32LE reference.
LIMIT = 0.0002  # YlContainerOutputTests unshifted PCM limit.


def decode_bridge(path, packets):
    lib = c.CDLL(str(path.resolve()))
    lib.ylf_dts_create.argtypes = []
    lib.ylf_dts_create.restype = c.c_void_p
    lib.ylf_dts_decode.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t, c.POINTER(c.c_float),
                                   c.c_int32, c.POINTER(c.c_int32), c.POINTER(c.c_int32)]
    lib.ylf_dts_decode.restype = c.c_int32
    lib.ylf_dts_free.argtypes = [c.c_void_p]
    lib.ylf_dts_free.restype = None
    decoder = lib.ylf_dts_create()
    assert decoder
    pcm = array.array('f')
    block = (c.c_float * (FRAMES * CHANNELS))()
    count, rate = c.c_int32(), c.c_int32()
    try:
        for packet in packets:
            status = lib.ylf_dts_decode(decoder, packet, len(packet), block, FRAMES,
                                        c.byref(count), c.byref(rate))
            assert (status, count.value, rate.value) == (0, FRAMES, RATE)
            pcm.frombytes(bytes(block))
    finally:
        lib.ylf_dts_free(decoder)
    return pcm


def frame_at(timestamps, start_us):
    # Capture stamps each sample relative to its own packet PTS, truncated to us.
    # DTS packets span 10 2/3 ms while the Matroska clock has millisecond ticks.
    for i, pts in enumerate(timestamps):
        delta = start_us - int(pts * 1000000)
        frame = (delta * RATE + 999999) // 1000000
        if 0 <= frame < FRAMES and frame * 1000000 // RATE == delta:
            return i * FRAMES + frame
    raise ValueError(f'no packet sample at {start_us}us')


def verify(bridge, reference_binary, matrix_dir):
    fixture = ROOT / f'packages/yl_player/example/assets/test_media/format_matrix/{CASE}.mkv'
    media_hash, bridge_hash = sha(fixture.read_bytes()), sha(bridge.read_bytes())
    timestamps, packets = read_packets(fixture)
    assert len(packets) == 375
    with tempfile.TemporaryDirectory() as tmp:
        stream = Path(tmp) / 'input.dts'
        stream.write_bytes(b''.join(packets))
        reference = array.array('i', subprocess.check_output([reference_binary, stream]))
    actual = decode_bridge(bridge, packets)
    assert len(actual) == len(reference) == 192000 * CHANNELS
    peaks = compare(actual, reference, 0, CHANNELS, SCALE, LIMIT)

    matrix = json.loads((matrix_dir / 'matrix-result.json').read_bytes())
    assert matrix['formatScopeAcceptance'] and matrix['supportedRows'] == 40
    records = json.loads(lzma.decompress((matrix_dir / 'records.json.xz').read_bytes()))
    windows = []
    for record in records:
        cell = record['cell']
        if cell['caseId'] != CASE:
            continue
        assert cell['mediaHash'] == media_hash
        row, = record['rows']
        assert row['buildSha256'] == matrix['buildSha256']
        assert {img['image']: img['sha256'] for img in row['loadedImages']}['YlFFmpegBridge'] == bridge_hash
        for phase in row['phases']:
            for win in phase['pcmWindows']:
                raw = base64.b64decode(win['pcmF32LE'], validate=True)
                assert sha(raw) == win['pcmSha256'] and len(raw) == 8192 * CHANNELS * 4
                assert (win['rate'], win['frames'], win['channels']) == (RATE, 8192, CHANNELS)
                start = frame_at(timestamps, win['startUs'])
                peak = compare(array.array('f', raw), reference, start, CHANNELS, SCALE, LIMIT)
                windows.append(dict(transport=cell['transport'], phase=phase['phase'], marker=win['marker'],
                                    startUs=win['startUs'], startFrame=start, frames=8192, peakByChannel=peak))
    phases = [('play', n) for n in range(4)] + [('seek-1250', 1), ('seek-2250', 2), ('seek-0', 0)]
    assert [(w['transport'], w['phase'], w['marker']) for w in windows] == [
        (t, p, n) for t in ('file', 'http') for p, n in phases]
    return dict(caseId=CASE, matrixId=matrix['matrixId'], buildSha256=matrix['buildSha256'],
                mediaSha256=media_hash, bridgeSha256=bridge_hash, referenceBinarySha256=sha(reference_binary.read_bytes()),
                frames=len(actual)//CHANNELS, packetCount=len(packets), rate=RATE, channels=CHANNELS,
                referenceS32Sha256=sha(reference.tobytes()), bridgeFloat32Sha256=sha(actual.tobytes()),
                peakLimit=LIMIT, peakByChannel=peaks, publicWindows=windows)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('bridge', 'reference', 'matrix', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    if not __debug__:
        parser.error('PCM verification requires Python assertions enabled')
    result = verify(args.bridge, args.reference, args.matrix)
    with args.output.open('x') as out:
        json.dump(result, out, indent=2, allow_nan=False)
        out.write('\n')

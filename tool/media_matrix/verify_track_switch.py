"""Compare macOS backend track-switch captures with full-stream independent PCM."""
import argparse
import array
import base64
import json
from pathlib import Path
import struct
import subprocess
import tempfile

from independent_pcm import compare, read_packets, sha

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / 'packages/yl_player/example/assets/test_media/pcm_alignment'
EVIDENCE = ROOT / 'docs/superpowers/reports/evidence'
RATE = 48000
TARGET_US = 2500000
LIMIT = 0.0002


def decode_reference(fixture, track, packets, args):
    if track == 4:  # The player uses Apple's FLAC converter.
        raw = subprocess.check_output(['ffmpeg', '-v', 'error', '-xerror', '-c:a:3', 'flac', '-i', str(fixture),
                                      '-map', '0:a:3', '-c:a', 'pcm_f32le', '-f', 'f32le', '-'])
        return array.array('f', raw), 1

    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / 'stream'
        if track == 3:
            source.write_bytes(b''.join(packets))
            raw = subprocess.check_output([args.dts, source])
            return array.array('i', raw), 2**31
        source.write_bytes(b''.join(struct.pack('>I', len(packet)) + packet for packet in packets))
        raw = subprocess.check_output([args.dolby, 'ac3' if track == 1 else 'eac3', source])
        return array.array('h', raw), 2**15


def retained_packets(table):
    result = []
    for packet in table:
        skip = max(0, ((TARGET_US - packet['ptsUs']) * RATE + 999999) // 1000000)
        if skip < packet['count']:
            pts = packet['ptsUs'] + (skip * 1000000 + RATE - 1) // RATE
            result.append((packet['offset'] + skip, pts, packet['count'] - skip))
    return result


def verify(args):
    fixture = MEDIA / 'p03-pcm-switch.mkv'
    metadata = json.loads((MEDIA / 'p03-pcm-reference.json').read_bytes())
    fixture_hash = sha(fixture.read_bytes())
    assert fixture_hash == metadata['fixtureSha256']
    summary = json.loads(args.summary.read_bytes())
    assert summary['result'] == 'Passed' and summary['passedTests'] == 1 and summary['failedTests'] == 0
    manifest, = json.loads((args.attachments / 'manifest.json').read_bytes())
    assert 'testCodecTrackSwitchPreservesTargetSamplesAndTail' in manifest['testIdentifier']
    captures = [json.loads((args.attachments / item['exportedFileName']).read_bytes())
                for item in sorted(manifest['attachments'], key=lambda a: a['timestamp'])]
    assert len(captures) == 4
    builds = {c['decoderBuild'] for c in captures}
    decoder_build, = builds
    dolby = json.loads((EVIDENCE / '2026-11-03-macos-dolby-independent-pcm/result.json').read_bytes())
    dts = json.loads((EVIDENCE / '2026-11-03-macos-dts-independent-pcm/result.json').read_bytes())
    assert sha(args.dolby.read_bytes()) == dolby['referenceBinarySha256']
    assert sha(args.dts.read_bytes()) == dts['referenceBinarySha256']
    expected_hash = {1: dolby['cases'][0]['referenceS16Sha256'], 2: dolby['cases'][1]['referenceS16Sha256'],
                     3: dts['referenceS32Sha256']}
    previous = 1
    results = []
    for capture, track in zip(captures, [2, 3, 4, 1]):
        channels = 6 if track == 1 else 2
        assert (capture['fixtureSha256'], capture['targetUs'], capture['rate'], capture['channels']) == (
            fixture_hash, TARGET_US, RATE, channels)
        assert (capture['previous'], capture['selected']) == (f'audio-{previous}', f'audio-{track}')
        spec = next(t for t in metadata['tracks'] if t['track'] == track and t['channels'] == channels)
        timestamps, packets = read_packets(fixture, track - 1)
        table = spec['packetFrames']
        assert [p * 1000000 for p in timestamps] == [p['ptsUs'] for p in table]
        reference, scale = decode_reference(fixture, track, packets, args)
        ref_hash = sha(reference.tobytes())
        assert ref_hash == (spec['pcmSha256'] if track == 4 else expected_hash[track])
        assert len(reference) == spec['frames'] * channels
        retained = retained_packets(table)
        assert capture['frames'] == [n for _, _, n in retained]
        assert len(capture['ptsUs']) == len(retained)
        assert all(abs(actual - pts) <= 1 for actual, (_, pts, _) in zip(capture['ptsUs'], retained))
        start = retained[0][0]
        pcm = array.array('f', base64.b64decode(capture['pcmF32LE'], validate=True))
        assert sum(capture['frames']) == spec['frames'] - start == len(pcm) // channels
        peak = compare(pcm, reference, start, channels, scale, LIMIT)
        results.append(dict(previous=previous, selected=track, codec=spec['codec'], channels=channels,
                            firstPtsUs=capture['ptsUs'][0], firstReferenceFrame=start,
                            retainedFrames=len(pcm)//channels, blocks=len(retained), peakByChannel=peak,
                            referenceSha256=ref_hash, capturedSha256=sha(pcm.tobytes())))
        previous = track
    return dict(fixtureSha256=fixture_hash, decoderBuild=decoder_build, rate=RATE, targetUs=TARGET_US,
                peakLimit=LIMIT, switches=results)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('attachments', 'summary', 'dolby', 'dts', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    if not __debug__:
        parser.error('PCM verification requires Python assertions enabled')
    result = verify(args)
    with args.output.open('x') as out:
        json.dump(result, out, indent=2, allow_nan=False)
        out.write('\n')

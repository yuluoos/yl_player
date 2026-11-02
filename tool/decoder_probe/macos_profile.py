"""Export a per-image macOS AV1 profile only from independently qualified example runs."""
import argparse
import hashlib
import json
import math
import plistlib
import subprocess
from pathlib import Path

LIMIT_NAMES = ('maxOwnedBytes', 'maxFrames', 'maxPacketBytes', 'maxCpuNs', 'maxDecodeWallNs')


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def observations(directory, phase, expected_frames):
    receipt = json.loads((directory/'receipt.json').read_text())
    require(receipt['passed'] is True and receipt['exit'] == 0, f'{phase} did not pass')
    raw = (directory/'raw.log').read_bytes()
    lines = [line[line.index('QUAL_'):] for line in raw.decode().splitlines() if 'QUAL_' in line]
    require(not any(line.startswith(('QUAL_ERROR', 'QUAL_BAD', 'QUAL_DROP')) for line in lines),
            f'{phase} contains a playback, power, thermal or drop failure')
    require([x for x in lines if x.startswith('QUAL_FINISH ')] == ['QUAL_FINISH 0'], 'missing completion')
    ids = {tuple(x.split()[1:]) for x in lines if x.startswith('QUAL_ID ')}
    require(len(ids) == 1, 'ambiguous decoder identity')
    model, os_build, images, frozen = ids.pop()
    require(frozen == str(phase == 'verification').lower(), 'wrong budget mode')
    ticks = [json.loads(x.split(' ', 1)[1]) for x in lines if x.startswith('QUAL_DART ')]
    require(len(ticks) >= 500 and 0 <= ticks[0]['us'] <= 5000000
            and ticks[-1]['status'] == 'completed' and ticks[-1]['position'] >= 1200000000
            and ticks[-1]['us'] >= 1200000000 and all(t['decoder'] == 'software' and t['drops'] == 0 for t in ticks),
            'continuous software playback unverified')
    require(all(0 < b['us'] - a['us'] <= 5000000 and b['position'] >= a['position']
                for a, b in zip(ticks, ticks[1:])), 'playback observation gap')
    systems = [json.loads(x.split(' ', 1)[1]) for x in lines if x.startswith('QUAL_SYSTEM ')]
    require(len(systems) >= 240 and all(x['status'] == 'observed' and x['droppedFrames'] == x['corruptedFrames'] == 0
                            for x in systems), 'system output unverified')
    decoded = [int(x.split()[1]) for x in lines if x.startswith('QUAL_DECODED ')]
    require([n for n in decoded if n] == [expected_frames], 'incomplete decoder output')
    timed = systems[-1]['totalFrames']
    if timed != expected_frames:
        # A separate legacy layer can show and dequeue PTS zero before the timed
        # endpoint attaches. Require evidence from this process to count it.
        require(timed == expected_frames - 1 and
                [x for x in lines if x.startswith('QUAL_LEGACY_DEQUEUE ')] == ['QUAL_LEGACY_DEQUEUE 0'] and
                any(x.startswith('QUAL_LEGACY total=') and int(x.split()[1][6:]) > 0 and x.endswith(' drops=0')
                    for x in lines), 'unaccounted displayed frames')
    samples = [x.split() for x in lines if x.startswith('QUAL_SAMPLE ')]
    require(len(samples) >= 500 and all(0 < int(b[2]) - int(a[2]) <= 5000000000
            for a, b in zip(samples, samples[1:])), 'incomplete resource observations')
    peaks = [x.split()[-5:] for x in lines if x.startswith(('QUAL_SAMPLE ', 'QUAL_END '))]
    maxima = dict(zip(LIMIT_NAMES, (max(map(int, series)) for series in zip(*peaks))))
    require(maxima == receipt['peaks'] and all(value > 0 for value in maxima.values()), 'peak mismatch')
    return (model, os_build, images), digest(raw), maxima, receipt['pid'], {x[1] for x in samples}


def issue(app, baseline, verification, protocol):
    config = json.loads(protocol.read_bytes())
    require(config['independentProcesses'] == 2 and config['minimumPlaybackSeconds'] >= 1200
            and config['requiredDroppedFrames'] == 0 and config['expectedVideoPackets'] > 0, 'invalid protocol')
    second = observations(verification, 'verification', config['expectedVideoPackets'])
    first = observations(baseline, 'baseline', config['expectedVideoPackets'])
    require(first[0] == second[0] and first[1] != second[1] and first[3] != second[3]
            and first[4].isdisjoint(second[4]), 'runs are not independent or builds differ')
    a, b = [json.loads((d/'plan.json').read_text()) for d in (baseline, verification)]
    require(a['product'] == b['product'] and a['protocolSha256'] == b['protocolSha256'] == digest(protocol.read_bytes()),
            'product or protocol changed')
    limits_file = (baseline/'limits.json').read_bytes()
    require(b['limitsSha256'] == digest(limits_file), 'verification did not attest to the frozen limits')
    limits = json.loads(limits_file)
    expected_limits = {'windowNs': config['cpuWindowNs']}
    for name, unit in zip(LIMIT_NAMES, (65536, 1, 4096, 1000000, 1000000)):
        expected_limits[name] = min(config['trialCeilings'][name], math.ceil(first[2][name]*1.25/unit)*unit)
    require(limits == expected_limits and all(max(first[2][n], second[2][n]) <= limits[n] for n in LIMIT_NAMES),
            'unqualified limits')
    plist = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    require(plist['CFBundleIdentifier'] == 'dev.ylplayer.ylPlayerExample', 'wrong formal host')
    signature = subprocess.run(['codesign', '--verify', '--strict', str(app)], capture_output=True)
    require(signature.returncode == 0, 'formal example signature is invalid')
    files = {str(p.relative_to(app)): digest(p.read_bytes()) for p in app.rglob('*') if p.is_file() and not p.is_symlink()}
    require(files == a['product'], 'target must be the frozen example app')
    video = config['videoConfiguration']
    require(video == dict(codec=12, profile=0, bitDepth=8, chroma=420, width=320, height=180,
                          fpsNumerator=24, fpsDenominator=1, threads=2, outputPixelFormat=875704438),
            'unmeasured video configuration')
    require(files[config['fixturePath']] == config['fixtureSha256'], 'qualification fixture changed')
    model, os_build, images = first[0]
    swift, codec = images.split(':')
    require(swift in files.values() and codec in files.values(), 'loaded code is not packaged')
    key = dict(model=model, osBuild=os_build, decoderBuild=images, **video)
    return dict(schemaVersion=1, key=key, limits=limits, baselineSHA256=first[1], verificationSHA256=second[1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'baseline', 'verification', 'protocol', 'output'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    try:
        profile = issue(args.app, args.baseline, args.verification, args.protocol)
        with args.output.open('x') as out:
            out.write(json.dumps(profile, indent=2)+'\n')
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        parser.exit(2, f'No profile issued: {error}\n')


if __name__ == '__main__':
    main()

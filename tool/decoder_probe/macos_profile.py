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


def freeze_limits(peaks, config):
    require(config['fixedDecodeWallNs'] == 42000000
            and config['trialCeilings']['maxDecodeWallNs'] == 42000000,
            'invalid fixed decode deadline')
    limits = {'windowNs': config['cpuWindowNs'], 'maxDecodeWallNs': config['fixedDecodeWallNs']}
    for name, unit in zip(LIMIT_NAMES[:-1], (65536, 1, 4096, 1000000)):
        limits[name] = min(config['trialCeilings'][name], math.ceil(peaks[name]*1.25/unit)*unit)
    require(all(peaks[name] <= limits[name] for name in LIMIT_NAMES), 'unqualified limits')
    return limits


def observations(directory, phase, expected_frames):
    receipt = json.loads((directory/'receipt.json').read_text())
    require(receipt['passed'] is True and receipt['exit'] == 0, f'{phase} did not pass')
    raw = (directory/'raw.log').read_bytes()
    public = [line[line.index('PUBLIC_'):] for line in raw.decode().splitlines() if 'PUBLIC_' in line]
    playback = [json.loads(line.split(' ', 1)[1]) for line in public if line.startswith('PUBLIC_PLAYBACK ')]
    disposal = [json.loads(line.split(' ', 1)[1]) for line in public if line.startswith('PUBLIC_DISPOSE ')]
    require(not any(line.startswith('PUBLIC_ERROR ') for line in public)
            and [x['transport'] for x in playback] == ['file', 'http']
            and [x['transport'] for x in disposal] == ['file', 'http']
            and all(0 <= x['elapsedUs'] <= 3000000 for x in disposal), 'incomplete control prelude')
    expected_markers = [('play', 0), ('play', 1), ('play', 2), ('play', 3),
                        ('seek-2000', 2), ('seek-1250', 1), ('seek-0', 0)]
    colors = ([255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255])
    expected_system_phases = ['play-0', 'play-1', 'play-2', 'play-3',
        'before-seek-2000', 'seek-2000', 'before-seek-1250', 'seek-1250',
        'before-seek-0', 'seek-0', 'completed']
    for record in playback:
        require(record['completed'] is True and record['decoder'] == 'software'
                and record['pixelVerificationMethod'] == 'native-renderer-displayed-buffer'
                and record['readbackWhilePaused'] is True
                and [(m['phase'], m['marker']) for m in record['markers']] == expected_markers
                and all(len(m['rgb']) == 3 and all(abs(a-b) <= 40 for a, b in zip(m['rgb'], colors[m['marker']]))
                        for m in record['markers']), 'unverified control prelude output')
        require([m['phase'] for m in record['systemSamples']] == expected_system_phases
                and all(m['status'] == 'observed' and m['totalFrames'] > 0
                        and m['droppedFrames'] == m['corruptedFrames'] == 0
                        and m['windowOcclusionVisible'] is True for m in record['systemSamples']),
                'unverified control prelude system output')
    require(any(x['status'] == 206 for x in playback[1]['requests']), 'unverified HTTP prelude')
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
    clocks = [json.loads(x.split(' ', 1)[1]) for x in lines if x.startswith('QUAL_CLOCK ')]
    require(len(clocks) >= 500 and all(x['samples'] > 0 and x['staleEvents'] == 0
            and 0 <= x['maximumAgeSeconds'] <= 0.1
            and 0 <= x['maximumWorkerGapSeconds'] <= 0.1 for x in clocks),
            'clock freshness or worker cadence unverified')
    require(all(0 < b['hostNs'] - a['hostNs'] <= 5000000000
                for a, b in zip(clocks, clocks[1:])), 'clock observation gap')
    systems = [json.loads(x.split(' ', 1)[1]) for x in lines if x.startswith('QUAL_SYSTEM ')]
    require(len(systems) >= 240 and all(x['status'] == 'observed' and x['droppedFrames'] == x['corruptedFrames'] == 0
                            for x in systems), 'system output unverified')
    decoded = [int(x.split()[1]) for x in lines if x.startswith('QUAL_DECODED ')]
    require([n for n in decoded if n] == [expected_frames], 'incomplete decoder output')
    starts = [int(x.split()[1]) for x in lines if x.startswith('QUAL_CONTINUOUS_START ')]
    total = [int(x.split()[1]) for x in lines if x.startswith('QUAL_TOTAL_DECODED ')]
    require(len(starts) == 1 and starts[0] > 0 and total == [starts[0]+expected_frames],
            'unaccounted decoded frame offset')
    timed = systems[-1]['totalFrames']
    if timed != expected_frames:
        # The public paused-first-frame milestone can precede the timed layer.
        # Count its one displayed frame only with observed, distinct layer identity.
        initial = [json.loads(x.split(' ', 1)[1]) for x in lines if x.startswith('QUAL_PREFLIGHT ')]
        require(timed == expected_frames - 1 and
                len(initial) == 1 and initial[0]['firstFrameCompleted'] is True and
                initial[0]['positionUs'] == 0 and initial[0]['decoder'] == 'software',
                'unaccounted displayed frames')
        preview = initial[0]['layer']
        require(preview['status'] == 'observed' and preview['totalFrames'] == 1 and
                preview['droppedFrames'] == preview['corruptedFrames'] == 0 and
                preview['surfaceHasBounds'] is True and preview['windowOcclusionVisible'] is True and
                bool(preview['layerIdentity']) and bool(systems[0]['layerIdentity']) and
                all(x['layerIdentity'] == systems[0]['layerIdentity'] != preview['layerIdentity'] for x in systems),
                'unaccounted displayed frames')
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
            and config['requiredDroppedFrames'] == 0 and config['expectedVideoPackets'] > 0
            and config['controlPrelude'] == 'public-file-http-paused-readback-seek-v1', 'invalid protocol')
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
    expected_limits = freeze_limits(first[2], config)
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
                          fpsNumerator=24, fpsDenominator=1, threads=1, outputPixelFormat=875704438),
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

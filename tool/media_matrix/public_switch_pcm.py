"""Verification of public Flutter selection events and the corresponding native PCM."""
import array
import base64
import argparse
import gzip
from pathlib import Path
import json
from types import SimpleNamespace

from independent_pcm import compare, read_packets, sha
from verify_track_switch import EVIDENCE, LIMIT, MEDIA, RATE, decode_reference

ORDER = ['audio-2', 'audio-3', 'audio-4', 'audio-1']
FIXTURE = MEDIA / 'p03-pcm-switch.mkv'
CASE = 'p03-pcm-switch'


def configure_plan(plan):
    media_hash = sha(FIXTURE.read_bytes())
    plan['trackSwitchOrder'] = ORDER
    plan['planned'] = [dict(caseId=CASE, file=FIXTURE.name, mediaHash=media_hash, transport=t)
                       for t in ('file', 'http')]
    plan['phases'] = [dict(phase='play', markers=[0, 1, 2, 3])] + [
        dict(phase='seek-2500', markers=[2]) for _ in ORDER]


def reference_tracks(dolby, dts):
    pinned = json.loads((MEDIA / 'p03-pcm-reference.json').read_bytes())
    assert pinned['fixtureSha256'] == sha(FIXTURE.read_bytes())
    native = json.loads((EVIDENCE / '2026-11-03-macos-switch-independent-pcm/result.json').read_bytes())
    provenance = json.loads((EVIDENCE / '2026-11-03-macos-switch-independent-pcm/provenance.json').read_bytes())
    assert all(sha(tool.read_bytes()) == provenance['referenceBinaryHashes'][tool.name] for tool in (dolby, dts))
    assert [f"audio-{c['selected']}" for c in native['switches']] == ORDER
    references = []
    for capture in native['switches']:
        track, channels = capture['selected'], capture['channels']
        table = next(t['packetFrames'] for t in pinned['tracks'] if t['track'] == track and t['channels'] == channels)
        pts, packets = read_packets(FIXTURE, track - 1)
        assert [p * 1000000 for p in pts] == [p['ptsUs'] for p in table]
        pcm, divisor = decode_reference(FIXTURE, track, packets, SimpleNamespace(dolby=dolby, dts=dts))
        assert sha(pcm.tobytes()) == capture['referenceSha256']
        references.append((channels, table, pcm, divisor))
    return references


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check(plan, rows, events, refs):
    require(len(rows) == 2 and len(events) == 8, 'incomplete transports or switch receipts')
    require(plan['trackSwitchOrder'] == ORDER, 'wrong switch sequence')
    sessions = set()
    results = []
    sdk = json.loads((EVIDENCE / '2026-11-03-macos-qualified-format-matrix/qualification/yl-player-qualified-av1.json').read_bytes())
    for index, (row, transport) in enumerate(zip(rows, ('file', 'http'))):
        session = row['sessionId']
        require(session and session not in sessions, 'session reused across transports')
        sessions.add(session)
        origin = dict(buildSha256=plan['buildSha256'], sessionId=session, runId=plan['runId'])
        require(all(row[k] == v for k, v in origin.items()) and row['publicSessionId'] == session and
                row['testSha256'] == origin['buildSha256'], 'row identity mismatch')
        require(row['caseId'] == CASE and row['transport'] == transport and
                row['mediaHash'] == sha(FIXTURE.read_bytes()) and row['outcome'] == 'passed' and
                all(row[k] is True for k in ('sourceVerified','identityVerified','completed','disposed','nativeViewAttached')) and
                row['releasedAudioBytes'] == 0 and row['audioClockMethod'] == 'renderer-paused-consumption' and
                row['publicApi'] == 'YlPlayerController/YlPlayerView', 'source, surface or lifecycle evidence missing')
        images = {x['image']: x['sha256'] for x in row['loadedImages']}
        require(images['yl-player-apple'] + ':' + images['YlFFmpegBridge'] == sdk['key']['decoderBuild'], 'SDK mismatch')
        if transport == 'http':
            net = row['networkReceipt']
            require(row['networkPolicy'] == 'managed' and net['runId'] == plan['runId'] and
                    net['mediaHash'] == row['mediaHash'] and net['requests'] > 0 and net['bytesServed'] > 0 and
                    net['rejected'] == 0, 'managed HTTP unverified')
        require([p['phase'] for p in row['phases']] == ['play'] + ['seek-2500'] * 4, 'phase sequence mismatch')
        previous = 'audio-1'
        for ordinal, (selected, phase, reference) in enumerate(zip(ORDER, row['phases'][1:], refs)):
            event = events[index * 4 + ordinal]
            require(event == dict(**origin, transport=transport, previous=previous, selected=selected,
                                  ordinal=ordinal, targetMs=2500, completed=True), 'public selection mismatch')
            win, = phase['pcmWindows']
            require(all(win[k] == v and phase[k] == v for k, v in origin.items()), 'window identity mismatch')
            channels, table, pcm, divisor = reference
            raw = base64.b64decode(win['pcmF32LE'], validate=True)
            require(win['phase'] == 'seek-2500' and win['marker'] == 2 and win['rate'] == RATE and
                    win['channels'] == channels and win['frames'] == 8192 and len(raw) == 8192 * channels * 4 and
                    sha(raw) == win['pcmSha256'], 'PCM shape or hash mismatch')
            # Same first sample at or after the 2.6s window as the native probe,
            # using the original packet PTS and the sample's truncated microseconds.
            for packet in table:
                skip = max(0, ((2600000 - packet['ptsUs']) * RATE + 999999) // 1000000)
                if skip < packet['count']:
                    break
            start = packet['offset'] + skip
            require(win['startUs'] == packet['ptsUs'] + skip * 1000000 // RATE, 'unexpected sample timestamp')
            peak = compare(array.array('f', raw), pcm, start, channels, divisor, LIMIT)
            clocks = [p['audioClockUs'] for p in phase['pixels'] if p['windowVisible'] is True and
                      p['displayRate'] == 0 and 2500000 <= p['audioClockUs'] < 3000000 and
                      all(abs(x-y) <= 24 for x,y in zip(p['value'], (0,0,255))) and len(p['value']) == 3]
            require(len(clocks) >= 2 and max(clocks)-min(clocks) >= 100000, 'missing paired blue frame observations')
            results.append(dict(**event, startFrame=start, startUs=win['startUs'], frames=8192,
                                channels=channels, peakByChannel=peak, pairedPixels=len(clocks)))
            previous = selected
    return results


def switch_result(plan, rows, status, stable, log, dolby, dts):
    events = [json.loads(line.split('P03_TRACK_SWITCH ', 1)[1]) for line in log.splitlines()
              if line.startswith(('P03_TRACK_SWITCH ', 'flutter: P03_TRACK_SWITCH '))]
    try:
        require(stable and status.get('passed') is True and status.get('identityVerified') is True and
                status.get('artifactsUnchanged') is True and status.get('runId') == plan['runId'],
                status.get('failure') or 'unverified framework result or frozen bundle')
        switches = check(plan, rows, events, reference_tracks(dolby, dts))
    except (AssertionError, ValueError, KeyError) as error:
        return dict(scopeAcceptance=False, errors=[str(error)], events=events)
    return dict(scopeAcceptance=True, errors=[], events=events, switches=switches, peakLimit=LIMIT)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Replay a macOS public track-switch collection')
    for name in ('directory', 'transcript', 'dolby', 'dts'):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    if not __debug__:
        parser.error('PCM verification requires Python assertions enabled')
    directory = args.directory
    plan = json.loads((directory / 'plan.json').read_bytes())
    receipt = json.loads((directory / 'result.json').read_bytes())
    manifest = base64.b64decode(plan['productManifest'], validate=True)
    require(sha(manifest) == plan['buildSha256'] == plan['testSha256'], 'manifest identity mismatch')
    result = switch_result(plan, json.loads(gzip.decompress((directory / 'rows.json.gz').read_bytes())),
                           json.loads((directory / 'status.json').read_bytes()),
                           receipt['collectionCompleted'] and receipt['collectorError'] is None,
                           args.transcript.read_text(), args.dolby, args.dts)
    require(result['scopeAcceptance'] and result['switches'] == receipt['switches'], 'switch replay failed')
    print(f"Verified {len(result['switches'])} public track switches")

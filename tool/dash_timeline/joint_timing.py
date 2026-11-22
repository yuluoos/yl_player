#!/usr/bin/env python3
"""Join OPPO DASH timing probes by fixture and run. Times are device monotonic observations."""
import argparse
from collections import defaultdict
import json
from pathlib import Path

from joint_observations import decode_records


def summarize_timing(log):
    events = defaultdict(list)
    for line in log.splitlines():
        if 'P01_AV_EVENT:' in line:
            event = json.loads(line.split('P01_AV_EVENT:', 1)[1])
            events[event['fixture'], event['run']].append(event)

    results = []
    seen = set()
    for record in decode_records(log):
        key = (record['fixture'], record['run'])
        if key in seen:
            raise ValueError(f'Duplicate run {key}')
        seen.add(key)
        rows = record['rows']
        first = rows[0]
        if first['videoPtsUs'] != 0:
            raise ValueError(f'Initial output absent for {key}')
        trace = events[key]

        def single_event(kind):
            event, = [e for e in trace if e['event'] == kind]
            return event

        def relative_us(event):
            return (event['hostNs'] - first['observedHostNs']) / 1000

        enter = single_event('firstWriteEnter')
        leave = single_event('firstWriteReturn')
        clock = single_event('firstObservedClock')
        sink_play = next(e for e in trace if e['event'] == 'sinkPlay')
        run = dict(fixture=key[0], run=key[1], frames=len(rows),
                   missingClockPtsUs=[r['videoPtsUs'] for r in rows if r['audioUs'] is None],
                   firstFrameClockUs=first['audioUs'], firstWriteEnterUs=relative_us(enter),
                   firstWriteReturnUs=relative_us(leave), firstWriteAccepted=leave['accepted'],
                   clockAtWriteEnterUs=enter['clockUs'], clockAtWriteReturnUs=leave['clockUs'],
                   firstClockObservedUs=relative_us(clock), firstClockPositionUs=clock['positionUs'],
                   firstSinkPlayUs=relative_us(sink_play),
                   firstFrameAudioAtMetadataUs=first.get('audioAtMetadataUs'),
                   firstFrameMetadataToReleaseUs=((first['imageTimestampNs'] - first['metadataHostNs']) / 1000
                                                 if first.get('metadataHostNs') is not None else None),
                   firstFrameProjectedAudioUs=first.get('audioProjectedAtReleaseUs'),
                   firstFrameReleaseToSinkPlayUs=(sink_play['hostNs'] - first['imageTimestampNs']) / 1000)
        switch = next((i for i, r in enumerate(rows) if r['representation'] == 'p1-video'), None)
        if switch is not None:
            row = rows[switch]
            fmt, = [e for e in trace if e['event'] == 'videoFormat' and e['id'] == 'p1-video']
            decoders = [e for e in trace if e['event'] == 'videoDecoderInitialized']
            if not decoders:
                raise ValueError(f'No decoder timing for {key}')
            pts = row['videoPtsUs']
            prior = rows[switch-1]
            init = decoders[-1]
            # Android reports codec completion in elapsedRealtime milliseconds. Map it
            # to the monotonic frame clock with the two timestamps at event delivery.
            init_ns = init['hostNs'] + init['initializedElapsedMs'] * 1_000_000 - init['callbackElapsedNs']
            run['switch'] = dict(
                ptsUs=pts, previousPtsUs=prior['videoPtsUs'], nextPtsUs=rows[switch+1]['videoPtsUs'],
                videoReuseResult=fmt['reuseResult'], discardReasons=fmt['discardReasons'],
                decoders=[dict(name=e['decoder'], initMs=e['durationMs']) for e in decoders],
                newDecoderReadyBeforeReleaseUs=(row['imageTimestampNs']-init_ns)/1000 if len(decoders) > 1 else None,
                audioLeadAtMetadataUs=(row['audioAtMetadataUs'] - pts if row['audioAtMetadataUs'] is not None else None),
                deltaUs=row['deltaUs'], rawDeltaUs=row['rawDeltaUs'],
                metadataToReleaseUs=(row['imageTimestampNs']-row['metadataHostNs'])/1000,
                gpuReadUs=(row['gpuEndNs']-row['gpuStartNs'])/1000,
                releaseToAudioObservationUs=(row['observedHostNs']-row['imageTimestampNs'])/1000,
                gpuEndToAudioObservationUs=(row['observedHostNs']-row['gpuEndNs'])/1000,
                nextDeltaUs=rows[switch+1]['deltaUs'],
            )
        results.append(run)
    if not results or seen != set(events):
        raise ValueError('Timing events and frame runs must match')
    return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize_timing(args.capture.read_text()), indent=2, allow_nan=False))

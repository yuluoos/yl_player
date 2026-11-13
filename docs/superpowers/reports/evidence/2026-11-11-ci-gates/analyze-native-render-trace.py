"""Offline pre/post render timing analysis; thresholds select detail, not pass/fail."""
import argparse
import json
from pathlib import Path


def analyze(trace):
    scale = trace['timebaseNumer'] / trace['timebaseDenom'] / 1000
    rate = trace['sampleRate']
    pre_mask, post_mask = trace['preRenderMask'], trace['postRenderMask']
    sample_mask, host_mask = trace['sampleTimeValidMask'], trace['hostTimeValidMask']
    rows = trace['entries']
    pairs, intervals, unmatched, stack = [], [], [], []
    previous = None
    for index, row in enumerate(rows):
        observed, host, sample, frames, valid, action = row
        if action & pre_mask:
            item = {'index': index, 'sampleTime': sample, 'frames': frames,
                    'observedHostTicks': observed, 'audioHostTicks': host,
                    'audioHostValid': bool(valid & host_mask)}
            if valid & host_mask:
                item['observedMinusAudioHostUs'] = (observed-host)*scale
            if previous:
                old_index, old = previous
                interval = {'previousIndex': old_index, **item,
                            'entryGapUs': (observed-old[0])*scale,
                            'previousFrameDurationUs': old[3]/rate*1e6}
                if valid & sample_mask and old[4] & sample_mask and sample is not None and old[2] is not None:
                    delta = sample-old[2]
                    interval['sampleDeltaMinusPreviousFrames'] = delta-old[3]
                    if valid & host_mask and old[4] & host_mask:
                        interval['audioHostStepMinusSampleStepUs'] = (host-old[1])*scale-delta/rate*1e6
                intervals.append(interval)
            previous = (index, row)
            stack.append((index, row))
        if action & post_mask:
            if not stack:
                unmatched.append({'postIndex': index})
                continue
            pre_index, pre = stack.pop()
            pairs.append({'preIndex': pre_index, 'postIndex': index, 'sampleTime': pre[2],
                          'frames': pre[3], 'renderElapsedUs': (observed-pre[0])*scale,
                          'sameAudioStamp': row[1:5] == pre[1:5]})
    unmatched.extend({'preIndex': index} for index, _ in stack)
    return {
        'scope': trace['scope'], 'entryCount': len(rows), 'overflow': trace['overflow'],
        'removeStatus': trace['removeStatus'], 'pairedRenders': len(pairs),
        'unmatched': unmatched, 'stampMismatches': [x for x in pairs if not x['sameAudioStamp']],
        'maximumRenderElapsedUs': max((x['renderElapsedUs'] for x in pairs), default=0),
        'maximumEntryGapUs': max((x['entryGapUs'] for x in intervals), default=0),
        'sampleJumpCount': sum(abs(x.get('sampleDeltaMinusPreviousFrames', 0)) > 0.5 for x in intervals),
        'hostStepResidualOver2msCount': sum(abs(x.get('audioHostStepMinusSampleStepUs', 0)) > 2000 for x in intervals),
        'largestRenderIntervals': sorted(pairs, key=lambda x:x['renderElapsedUs'], reverse=True)[:10],
        'largestEntryIntervals': sorted(intervals, key=lambda x:x['entryGapUs'], reverse=True)[:10],
        'clockDiscontinuities': [x for x in intervals if abs(x.get('sampleDeltaMinusPreviousFrames', 0)) > 0.5 or abs(x.get('audioHostStepMinusSampleStepUs', 0)) > 2000][:32],
        'limits': 'Render elapsed includes preemption, not CPU execution time; audio host timestamp is not a HAL deadline. Truncated traces cannot exclude later anomalies.',
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    row = json.loads(args.input.read_text())
    result = analyze(row['trace'])
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print({k:result[k] for k in ('entryCount','overflow','pairedRenders','maximumRenderElapsedUs','maximumEntryGapUs','sampleJumpCount','hostStepResidualOver2msCount')})

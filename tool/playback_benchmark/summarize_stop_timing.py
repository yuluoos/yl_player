"""Segmented EOF stop latency with a predeclared longer hold control."""
import argparse
import json
import math
from pathlib import Path
from run_audio_integration_resources import validate_stop_rows
from summarize_callback_wrappers import load_wrapper
from summarize_stop_boundary import validate_pair

KEYS=('ackReturned','sleepStarted','sleepFinished','actionStarted','actionFinished',
      'assertionsFinished','probeEntered','recorderSettled','memoryReadFinished','rowCaptured')


def validate_timing_rows(rows, mode, candidate=False):
    validate_stop_rows(rows,mode,60,'decoded-60.mkv',candidate=candidate)
    def require(ok,message):
        if not ok:raise ValueError(message)
    require(all(r['timingProfile']=='long-hold-v1' for r in rows), 'Wrong timing profile')
    require(all(r['boundaryTiming']=={} for r in rows[:3]), 'Premature timing')
    t=rows[3]['boundaryTiming']
    require(set(t)==set(KEYS), 'Missing/extra timing segment')
    require(all(type(v) in (int,float) and math.isfinite(v) for v in t.values()), 'Nonfinite timing')
    values=[rows[2]['uptime']]+[t[k] for k in KEYS]
    require(all(b>=a for a,b in zip(values,values[1:])), 'Unordered timing')
    require(t['rowCaptured']==rows[3]['uptime'], 'Timing not bound to row')
    require(all(r['boundaryTiming']==t for r in rows[3:]), 'Timing changed after observation')
    duration=t['sleepFinished']-t['sleepStarted']
    require(duration>=(30 if mode=='hold' else 2), 'Short control wait')
    require(all(math.isclose(r['interventionWaitSeconds'],duration,rel_tol=0,abs_tol=1e-6) for r in rows[3:]), 'Wrong recorded sleep')
    labels=('drainedRow',)+KEYS
    segments={a+'To'+b:values[i+1]-values[i] for i,(a,b) in enumerate(zip(labels,labels[1:]))}
    return dict(boundaryMode=mode,segments=segments,totalSeconds=values[-1]-values[0],
        nativeStopSeconds=t['actionFinished']-t['actionStarted'] if mode=='stop' else None,
        actionSeconds=t['actionFinished']-t['actionStarted'],
        afterAckSeconds=t['rowCaptured']-t['ackReturned'])


def validate_timing_cell(c, candidate=False):
    if c['result'].get('stopTiming') is not True:raise ValueError('Missing timing collection flag')
    timing=validate_timing_rows(c['rows'],c['result']['boundaryMode'],candidate=candidate)
    probes={p['phase']:p for p in c['result']['probes']}
    for phase,p in probes.items():
        row=next(r for r in c['rows'] if r['phase']==phase)
        if not (math.isfinite(p['startedUptime']) and math.isfinite(p['endedUptime']) and row['uptime']<=p['startedUptime']<=p['endedUptime']):raise ValueError('Wrong heap timing')
    if probes['drained']['endedUptime']>c['rows'][3]['boundaryTiming']['ackReturned']:raise ValueError('ACK preceded heap end')
    timing['heapStartIntervalSeconds']=probes['intervened']['startedUptime']-probes['drained']['startedUptime']
    return timing


def validate_timing_pair(cells):
    comparison=validate_pair(cells)
    timings=[validate_timing_cell(c) for c in cells]
    hold=next(t for t in timings if t['boundaryMode']=='hold');stop=next(t for t in timings if t['boundaryMode']=='stop')
    coverage={k:hold[k]>=stop[k] for k in ('totalSeconds','afterAckSeconds','heapStartIntervalSeconds')}
    return dict(comparison=comparison,timings=timings,coverage=coverage,longerWaitControlCoversStop=all(coverage.values()),
        productionAdmission=False,downstreamBoundProven=False,exactRetainerProven=False,statisticalImprovementProven=False)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('directories',nargs=2,type=Path)
    args=parser.parse_args();print(json.dumps(validate_timing_pair([load_wrapper(p) for p in args.directories]),indent=2))

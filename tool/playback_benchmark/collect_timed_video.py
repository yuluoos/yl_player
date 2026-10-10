"""Fail-closed validation of native timed-video observations (no physical-output claim)."""
import argparse
import json
import math
from pathlib import Path


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def evaluate(observation, *, require_stall=True, require_candidate=True, require_audio_clock=False):
    failures=[]
    rows=observation.get('rows', [])
    protocol = observation.get('audioClockProtocol')
    if require_audio_clock and protocol != 1:
        failures.append('isolated audio clock protocol missing')
    if protocol == 1 or require_audio_clock:
        required = observation.get('audioClockRequired')
        if type(required) is not bool: failures.append('audio track requirement unavailable')
        for index, row in enumerate(rows):
            clock = row.get('audioClock')
            if not isinstance(clock, dict) or clock.get('required') is not required:
                failures.append(f'row {index}: audio clock requirement missing or inconsistent'); continue
            if required is True:
                if clock.get('isolated') is not True: failures.append(f'row {index}: audio clock not isolated')
                counts = ['samples', 'staleEvents', 'rejectedObservations']
                if any(type(clock.get(k)) is not int or clock[k] < 0 for k in counts):
                    failures.append(f'row {index}: audio clock counts invalid')
                elif clock['samples'] == 0 or clock['staleEvents'] != 0:
                    failures.append(f'row {index}: audio clock absent or stale')
                if any(not number(clock.get(k)) for k in ['maximumReadSeconds', 'maximumAgeSeconds']):
                    failures.append(f'row {index}: audio clock timings invalid')
                elif clock['maximumAgeSeconds'] > .1:
                    failures.append(f'row {index}: audio clock age exceeds 100ms')
    initial=next((r for r in rows if r.get('phase')=='playing'), {})
    final=next((r for r in reversed(rows) if r.get('phase')=='activeEnd'), {})
    if not initial or not final: failures.append('missing measurement boundaries')
    if any(r.get('windowOcclusionVisible') is not True for r in rows if r.get('phase') in ['playing','activeEnd']):
        failures.append('native window occluded or visibility unobserved')
    delta={}
    for name, row in [('start', initial), ('end', final)]:
        if require_candidate and row.get('candidateActuallyUsed') is not True: failures.append(f'{name}: timed endpoint not used')
        metrics=row.get('systemMetrics')
        if not isinstance(metrics, dict) or any(not number(metrics.get(k)) for k in ['total','dropped','corrupted','accumulatedDelay']):
            failures.append(f'{name}: system metrics unavailable or invalid')
    if not any('metrics unavailable' in f for f in failures) and initial and final:
        delta={key: final['systemMetrics'][key]-initial['systemMetrics'][key] for key in ['total','dropped','corrupted','accumulatedDelay']}
        if any(value<0 for value in delta.values()): failures.append('system metrics regressed')
        if delta['total']<=0: failures.append('no system output frames')
        if delta['dropped']!=0 or delta['corrupted']!=0: failures.append('system dropped/corrupted frames')
        if delta['total']>0 and delta['accumulatedDelay']/delta['total']>.1: failures.append('mean system delay exceeds 100ms')
    if final.get('applicationDrops')!=0: failures.append('application dropped frames')
    if require_candidate:
        if final.get('rejected')!=0: failures.append('worker rejected frames')
        gap=final.get('workerMaxGapSeconds')
        if not number(gap) or gap>.1: failures.append('worker gap unavailable or exceeds 100ms')
    if any(row.get('failures') for row in rows): failures.append('native playback errors')
    for phase in ['disposed','disposedLater']:
        row=next((r for r in rows if r.get('phase')==phase), {})
        if not row or row.get('ledgerBytes')!=0 or row.get('pending') is not False: failures.append(f'{phase}: resources not released')
    if observation.get('pausedPixelPresent') is not True: failures.append('paused native pixel unavailable')
    if require_stall:
        duration=observation.get('stallSeconds')
        if not number(duration) or duration<.25: failures.append('main stall intervention missing')
        submitted=observation.get('submittedDuringStall')
        if not number(submitted) or submitted<4: failures.append('no worker progress during main stall')
    return dict(passed=not failures, failures=failures, systemDelta=delta)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('observation', type=Path)
    parser.add_argument('--activation', action='store_true')
    parser.add_argument('--baseline', action='store_true')
    args=parser.parse_args()
    result=evaluate(json.loads(args.observation.read_text()), require_stall=not args.activation, require_candidate=not args.baseline)
    print(json.dumps(result, indent=2)); return 0 if result['passed'] else 1

if __name__=='__main__': raise SystemExit(main())

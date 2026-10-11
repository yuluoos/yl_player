#!/usr/bin/env python3
"""Join one public-state capture and its owned HTTP trace; never certify CAPs."""
import argparse
import json
import math
from pathlib import Path
import re


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def require(condition):
    if not condition:
        raise ValueError('Invalid or mismatched ABR capture')


def summarize(result, samples, requests, *, exit_code, server_summary=None):
    require(isinstance(result, dict) and result.get('schemaVersion') == 1)
    require(type(exit_code) is int)
    run = result.get('runId')
    require(isinstance(run, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}', run))
    require(result.get('mode') in ('auto', 'caps', 'fixed'))
    require(result.get('profileId') == 'down-and-recover-v1')
    for key in ['profileHash', 'mediaHash']:
        require(isinstance(result.get(key), str) and re.fullmatch(r'[0-9a-f]{64}', result[key]))
    require(isinstance(samples, list) and len(samples) <= 1024 and
            type(result.get('sampleCount')) is int and result['sampleCount'] == len(samples))
    require(isinstance(requests, list) and len(requests) <= 10000)
    require(type(result.get('cleaned')) is bool and result.get('outcome') in ('completed', 'failed', 'timeout'))
    require(result.get('endToEndLatencyUs') is None and result.get('physicalOutputVerified') is False and
            result.get('baselineComparable') is False and
            result.get('clockRelation') == 'load-vs-first-get-unsynchronized')
    for key in ['policyAckUs', 'firstFrameUs']:
        require(result.get(key) is None or number(result[key]))
    previous = -1
    violations = set()
    high_confirmed = False
    geometry_switches = 0
    last_geometry = None
    for sample in samples:
        require(isinstance(sample, dict) and sample.get('runId') == run)
        require(number(sample.get('elapsedUs')) and sample['elapsedUs'] >= previous)
        previous = sample['elapsedUs']
        require(number(sample.get('positionUs')) and type(sample.get('automatic')) is bool and
                type(sample.get('failed')) is bool and isinstance(sample.get('status'), str))
        for key in ['width', 'height', 'selectedWidth', 'selectedHeight', 'selectedBitrate', 'rebufferCount', 'rebufferUs']:
            require(key in sample and (sample[key] is None or number(sample[key])))
        geometry = ((sample['width'], sample['height'])
                    if sample['width'] is not None and sample['height'] is not None else None)
        if geometry is not None and last_geometry is not None and geometry != last_geometry:
            geometry_switches += 1
        last_geometry = geometry
        if result['mode'] == 'caps':
            if not sample['automatic']:
                violations.add('caps_selected_fixed_mode')
            if any(sample[k] is not None and sample[k] > cap for k,cap in
                   [('width',320),('height',180),('selectedWidth',320),('selectedHeight',180),('selectedBitrate',350000)]):
                violations.add('caps_output_exceeded')
        if result['mode'] == 'auto' and not sample['automatic']:
            violations.add('auto_mode_not_retained')
        if result['mode'] == 'fixed':
            if sample['automatic'] is False and geometry == (640,360):
                high_confirmed = True
            if (result.get('policyAckUs') is not None and
                    sample['elapsedUs'] >= result['policyAckUs'] and sample['automatic']):
                violations.add('fixed_returned_to_auto')
            if high_confirmed and geometry is not None and geometry != (640,360):
                violations.add('fixed_output_downgraded')
    if result['mode'] == 'fixed' and not high_confirmed:
        violations.add('fixed_high_unobserved')
    ids = set()
    total_bytes = 0
    request_failures = 0
    manifest_seen = False
    recovery = False
    for row in requests:
        require(isinstance(row, dict) and row.get('schemaVersion') == 1 and row.get('runId') == run and
                row.get('profile') == result['profileId'] and row.get('profileSha256') == result['profileHash'] and
                row.get('timelineMode') == 'first-get')
        identity = row.get('requestId')
        require(type(identity) is int and identity > 0 and identity not in ids)
        ids.add(identity)
        require(type(row.get('bodyBytesWritten')) is int and row['bodyBytesWritten'] >= 0)
        require(row.get('method') in ('GET','HEAD') and row.get('outcome') in
                ('complete','timeout','disconnected','client_io_error'))
        total_bytes += row['bodyBytesWritten']
        request_failures += row['outcome'] != 'complete' or row.get('status') not in (200,206)
        if row.get('timelineState') == 'pending':
            require(row['method'] == 'HEAD' and row.get('startMs') is None and row.get('endMs') is None)
            continue
        require(row.get('timelineState') == 'active' and number(row.get('startMs')) and
                number(row.get('endMs')) and row['endMs'] >= row['startMs'])
        if row.get('asset') == 'manifest.mpd':
            require(row.get('assetSha256') == result['mediaHash'])
            manifest_seen |= row['method'] == 'GET' and row['outcome'] == 'complete' and row['bodyBytesWritten'] > 0
        asset = row.get('asset')
        match = re.fullmatch(r'network-period-[0-9]+/(?:chunk-([012])-[0-9]+|init-([012]))\.m4s', asset or '')
        if match and row['method'] == 'GET':
            rendition = match.group(1) or match.group(2)
            if result['mode'] == 'caps' and rendition == '1':
                violations.add('caps_high_video_requested')
            if row['endMs'] >= 25000 and row['bodyBytesWritten'] > 0:
                recovery = True
    require(ids == set(range(1,len(ids)+1)))
    server_complete = False
    if server_summary is not None:
        require(isinstance(server_summary,dict) and set(server_summary)==
                {'acceptedConnections','rejectedConnections','recordedRequests'})
        require(all(type(v) is int and v>=0 for v in server_summary.values()))
        require(server_summary['recordedRequests']==len(requests))
        server_complete = (server_summary['acceptedConnections']==len(requests) and
                           server_summary['rejectedConnections']==0)
    # A partial failure can legitimately have no samples or no manifest.
    completed = (exit_code == 0 and result['outcome'] == 'completed' and result['cleaned'] and
                 bool(samples) and samples[-1]['status'] == 'completed' and
                 samples[-1]['positionUs'] >= 39500000 and manifest_seen and
                 result.get('firstFrameUs') is not None and
                 not any(s['failed'] for s in samples) and server_complete)
    def delta(key):
        values = [s[key] for s in samples]
        if not values or any(v is None for v in values) or any(b < a for a,b in zip(values,values[1:])):
            return None
        return values[-1] - values[0]
    return dict(schemaVersion=1, runId=run, mode=result['mode'], captureComplete=bool(completed),
                outcome=result['outcome'], processExitCode=exit_code, cleaned=result['cleaned'],
                violations=sorted(violations), observedGeometrySwitches=geometry_switches,
                fixedHighObserved=high_confirmed if result['mode']=='fixed' else None,
                rebufferCountDelta=delta('rebufferCount'), rebufferDurationUsDelta=delta('rebufferUs'),
                requestBodyBytesWritten=total_bytes, requestFailures=request_failures,
                requestCount=len(requests), mediaRequestReachedRecovery=recovery,
                maximumSampleGapUs=max((b['elapsedUs']-a['elapsedUs'] for a,b in zip(samples,samples[1:])),default=None),
                adaptationLatencyUs=None, endToEndLatencyUs=None, capabilityAccepted=False,
                physicalOutputVerified=False, baselineComparable=False)


def read_capture(path):
    require(Path(path).stat().st_size <= 16*1024*1024)
    return parse_capture(Path(path).read_text())


def parse_capture(text):
    """Parse already bounded capture bytes without reopening an archive file."""
    samples, results = [], []
    for line in text.splitlines():
        for marker,target in [('YL_ABR_SAMPLE=',samples),('YL_ABR_RESULT=',results)]:
            if marker in line:
                target.append(json.loads(line.split(marker,1)[1]))
    require(len(results)==1)
    return results[0],samples


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture',type=Path,required=True)
    parser.add_argument('--requests',type=Path,required=True)
    parser.add_argument('--exit-code',type=int,required=True)
    parser.add_argument('--server-stdout',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    try:
        result,samples=read_capture(args.capture)
        require(args.requests.stat().st_size<=16*1024*1024)
        requests=[json.loads(line) for line in args.requests.read_text().splitlines()]
        require(args.server_stdout.stat().st_size<=65536)
        server_rows=[json.loads(line) for line in args.server_stdout.read_text().splitlines()]
        require(len(server_rows)==2 and server_rows[0].get('runId')==result['runId'] and
                server_rows[0].get('profileSha256')==result['profileHash'] and
                server_rows[0].get('timelineMode')=='first-get')
        report=summarize(result,samples,requests,exit_code=args.exit_code,server_summary=server_rows[1])
    except (ValueError,KeyError,TypeError,OSError):
        parser.exit(2,'Invalid or mismatched ABR capture\n')
    with args.output.open('x') as out:
        json.dump(report,out,indent=2);out.write('\n')
    return 0 if report['captureComplete'] and not report['violations'] else 1


if __name__=='__main__':
    raise SystemExit(main())

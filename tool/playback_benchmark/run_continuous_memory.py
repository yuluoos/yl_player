"""Bounded live heap/VM probes of one continuous session, with recording off."""
import json
import os
from pathlib import Path
import sys
import threading
import time
from continuous import PROTOCOL, summarize_continuous
from run_continuous import collect
from run_lifetime_probes import capture_probe, raw_us
from run_timeline_comparison import capture_timeline
from run_resources import digest
from summarize import unique_object, reject_constant

WINDOWS=((0,10),(120,130),(230,240))
TOOLS=('timeline-control','heap','vmmap','dart-memory')


def diagnostic_protocol():
    return dict(PROTOCOL,id='continuous-off-memory-v2',tickWindows=WINDOWS,
        observers=TOOLS,observerTimeoutSeconds=10,rpcReadTimeoutSeconds=2,
        profiler='runtime false at tick 0; read back before each probe window',
        timeline='runtime empty streams at tick 0; read back before each probe window',
        startup='unchanged; intervention after first playing tick',clearTimeline=False,
        probeAttemptField='checkpoint ordinal 1..3; playback attempts remain one',
        windowClock='CLOCK_MONOTONIC_RAW; both observer endpoints inside tick edges',
        dartMemoryScope='application-and-system-isolate-groups',
        vmIdentity='exact PID plus application/system group IDs across all probes',
        cadenceFailure='retain failure; continue diagnostic probes; completion still requires original continuity gates')


def read_rows(path,run):
    rows=[]
    for line in path.read_text().splitlines(keepends=True):
        if not line.endswith('\n'):break  # A concurrent append is not malformed input.
        if 'YL_CONTINUOUS=' not in line:continue
        raw=line.split('YL_CONTINUOUS=',1)[1]
        if len(raw)>8192:raise ValueError('Oversized continuous record')
        rows.append(json.loads(raw,object_pairs_hook=unique_object,parse_constant=reject_constant))
        if len(rows)>247:raise ValueError('Excess continuous records')
    summary=summarize_continuous(rows,run)
    if any(r in summary['reasons'] for r in ('playback-state-invalid','resource-unavailable')):
        raise ValueError('Invalid live playback prefix')
    return rows


def qualify(probe,rows,run):
    if probe['status']!='captured':return False
    checkpoint=probe['attempt']
    if type(checkpoint) is not int or checkpoint not in (1,2,3) or probe['phase']!='live' or probe['tool'] not in TOOLS:
        raise ValueError('Invalid probe checkpoint')
    begin,end=WINDOWS[checkpoint-1]
    ticks={r['sequence']:r for r in rows if r['kind']=='tick'}
    if begin not in ticks or end not in ticks:return False
    a,b=ticks[begin],ticks[end]
    if (probe['runId']!=run or a['runId']!=run or b['runId']!=run or
        probe['pid']!=a['pid'] or probe['pid']!=b['pid'] or a['sessionId']!=b['sessionId']):
        raise ValueError('Probe identity changed')
    start,stop=probe['startedUs'],probe['endedUs']
    if type(start) is not int or type(stop) is not int or start<=0 or stop<start:
        raise ValueError('Invalid probe clock')
    return a['resource']['monotonicUs']<=start<=stop<=b['resource']['monotonicUs']


def verify_control(record,pid,identity):
    if record['status']!='captured':raise ValueError('Diagnostic control unavailable')
    c=record['control'];actual=c['vmIdentity']
    if (c['profilerAfter']['after'] is not False or c['after']['recordedStreams']!=[] or actual['pid']!=pid or
        not actual['groups'] or (identity is not None and actual!=identity)):
        raise ValueError('Recording state or VM identity mismatch')
    return actual


def verify_memory(record,identity):
    if record['status']!='captured':return
    m=record['memory']
    groups=sorted([dict(id=g['id'],kind=g['kind']) for g in m['groups']],key=lambda g:g['id'])
    if m['scope']!='application-and-system-isolate-groups' or m['forcedGC'] is not False or groups!=identity['groups']:
        raise ValueError('Memory VM identity mismatch')


def collect_memory(output,flutter):
    if any(k.startswith('MallocStackLogging') for k in os.environ):raise ValueError('Inherited stack logging must be absent')
    raw_us();output.mkdir(parents=True,exist_ok=False)
    protocol=dict(diagnostic_protocol(),scriptSha256=digest(Path(__file__)),flutter=flutter)
    (output/'protocol.json').write_text(json.dumps(protocol,indent=2)+'\n')
    records=[dict(attempt=i,phase='live',tool=t,status='not_observed',qualified=False)
             for i in (1,2,3) for t in TOOLS]
    errors=[];identity=None;run=None;rows=[];child=output/'run';worker_result=[]
    def save(complete=False):
        result=dict(schemaVersion=1,protocolSha256=digest(output/'protocol.json'),runId=run,
            vmIdentity=identity,records=records,errors=errors,complete=complete,
            plannedAttempts=1,plannedProbes=12,performanceBaseline=False,budgetAdmission=False,leakVerdict=None)
        pending=output/'memory-probes.pending.json'
        pending.write_text(json.dumps(result,indent=2)+'\n')
        pending.replace(output/'memory-probes.json')
    def work():
        try:worker_result.append(collect(child,flutter,memory_diagnostics=True))
        except Exception as e:errors.append('collector: '+type(e).__name__)
    save();worker=threading.Thread(target=work);worker.start()
    seen_size=None;attempted=set()
    try:
        while True:
            finished=not worker.is_alive()
            definitions=child/'defines.json';log=child/'playback.log'
            if definitions.exists() and log.exists():
                if run is None:run=json.loads(definitions.read_text())['YL_RESOURCE_RUN_ID']
                size=log.stat().st_size
                if size!=seen_size:
                    rows=read_rows(log,run);seen_size=size
                ticks={r['sequence']:r for r in rows if r['kind']=='tick'}
                for checkpoint,(begin,end) in enumerate(WINDOWS,1):
                    if checkpoint in attempted or begin not in ticks:continue
                    attempted.add(checkpoint);tick=ticks[begin]
                    marker=dict(attempt=checkpoint,phase='live',runId=run,pid=tick['pid'])
                    for j,tool in enumerate(TOOLS):
                        record=(capture_timeline(marker,child,'off' if checkpoint==1 else 'observe') if tool=='timeline-control'
                                else capture_probe(marker,tool,child,detailed=True,include_system=True))
                        records[(checkpoint-1)*4+j]=record;save()
                        if tool=='timeline-control':identity=verify_control(record,tick['pid'],identity)
                        if tool=='dart-memory':verify_memory(record,identity)
            if finished:break
            time.sleep(.1)
    except (OSError,ValueError,TypeError,KeyError) as e:
        errors.append('monitor: '+type(e).__name__+': '+str(e));save()
    finally:worker.join()
    try:
        # Re-parse after the writer stops, including its terminal result. A raw
        # truncated last line cannot pass the collector's complete gate.
        if run is not None:rows=read_rows(child/'playback.log',run)
        for record in records:record['qualified']=qualify(record,rows,run)
        playback=json.loads((child/'result.json').read_text())
        complete=(worker_result==[True] and playback['complete'] and not errors and
                  all(r['qualified'] for r in records) and summarize_continuous(rows,run)['complete'])
    except (OSError,ValueError,TypeError,KeyError) as e:
        errors.append('qualification: '+type(e).__name__+': '+str(e));complete=False
    save(complete)
    return complete


if __name__=='__main__':
    if len(sys.argv)!=3:raise SystemExit('Usage: run_continuous_memory.py NEW_DIRECTORY FLUTTER_EXECUTABLE')
    ok=collect_memory(Path(sys.argv[1]).resolve(),sys.argv[2])
    print('Continuous memory diagnostic captured.' if ok else 'Incomplete diagnostic; raw evidence retained.')
    raise SystemExit(0 if ok else 2)

"""Frozen, independent Timeline stream on/off comparison with identical MSL."""
import json
import os
from pathlib import Path
import subprocess
import sys
from run_allocation_stacks import collect_stacks
from run_lifetime_probes import raw_us
from run_memory_categories import EXECUTABLE
from run_resources import digest
from lifetime_windows import WINDOWS


def capture_timeline(marker,output,mode):
    r=dict(attempt=marker['attempt'],phase=marker['phase'],tool='timeline-control',
           runId=marker['runId'],pid=marker['pid'],status='unavailable',qualified=False,startedUs=raw_us())
    path=output/f"timeline-{r['attempt']}-{r['phase']}.txt";journal=path.with_suffix('.rpc.jsonl')
    try:
        actual=subprocess.check_output(['/bin/ps','-p',str(r['pid']),'-o','comm='],text=True,timeout=2).strip()
        if actual!=str(EXECUTABLE):raise ValueError('Owned executable mismatch')
        r['command']=[sys.executable,str(Path(__file__).with_name('timeline_control.py')),
                      str(output/'playback.log'),str(r['pid']),mode,str(journal)]
        with path.open('w') as stream:
            process=subprocess.run(r['command'],stdout=stream,stderr=stream,timeout=10)
        r['exitCode']=process.returncode;payload=json.loads(path.read_text())
        if process.returncode==0 and payload.get('status')=='captured' and payload.get('pid')==r['pid']:
            r.update(status='captured',control=payload['control'])
        else:r['status']='failed'
    except (OSError,ValueError,subprocess.SubprocessError) as e:r['errorType']=type(e).__name__
    finally:
        r['endedUs']=raw_us()
        for key,file in (('raw',path),('rpcJournal',journal)):
            if file.exists():r[key]=dict(file=file.name,sha256=digest(file),bytes=file.stat().st_size)
    return r


def collect_pair(output,flutter):
    if any(k.startswith('MallocStackLogging') for k in os.environ):raise ValueError('Inherited stack logging must be absent')
    raw_us();output.mkdir(parents=True,exist_ok=False)
    protocol=dict(schemaVersion=1,purpose='short-timeline-stream-comparison-v2',httpStreamEncoding='VM bracketed unquoted enum list',armOrder=['on','off'],
        plannedAttemptsPerArm=10,windows=WINDOWS,checkpointSeconds=20,
        observers=['timeline-control','heap','vmmap'],observerTimeoutSeconds=10,
        recordedStreams=dict(on=['Dart','Embedder','GC','Microtask'],off=[]),
        intervention='profiler false and selected streams at live-1; read-only at disposed-2/8',
        startup='unchanged; intervention after first load',clearTimeline=False,forcedGC=False,
        launchEnvironment=dict(MallocStackLogging='full',MallocStackLoggingNoCompact='1'),
        cacheState='os-cache-uncontrolled',continuousPlayback=False,
        scriptSha256=digest(Path(__file__)),flutter=flutter,performanceBaseline=False,budgetAdmission=False,leakVerdict=None)
    (output/'protocol.json').write_text(json.dumps(protocol,indent=2)+'\n')
    arms=[];matched=False;errors=[]
    for arm in protocol['armOrder']:
        collect_stacks(output/arm,flutter,timeline_arm=arm)
        result=json.loads((output/arm/'allocation-probes.json').read_text());result['arm']=arm;arms.append(result)
        (output/'comparison.json').write_text(json.dumps(dict(arms=arms,complete=False),indent=2)+'\n')
    if all(a['complete'] for a in arms):
        runs=[json.loads((output/arm/'run/result.json').read_text()) for arm in protocol['armOrder']]
        fields=('sourceHash','dependencies','artifactFingerprints','mediaHash','device','architecture','buildMode','plannedAttempts','protocol')
        controls=[a['records'][0]['control'] for a in arms]
        matched=(all(runs[0][k]==runs[1][k] for k in fields) and arms[0]['pid']!=arms[1]['pid']
                 and controls[0]['before']==controls[1]['before'])
        if not matched:errors.append('Matched conditions unavailable')
    result=dict(schemaVersion=1,protocolSha256=digest(output/'protocol.json'),arms=arms,
        matchedConditions=matched,errors=errors,complete=matched and all(a['complete'] for a in arms),
        performanceBaseline=False,budgetAdmission=False,leakVerdict=None)
    (output/'comparison.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['complete']

if __name__=='__main__':
    if len(sys.argv)!=3:raise SystemExit('Usage: run_timeline_comparison.py NEW_DIRECTORY FLUTTER_EXECUTABLE')
    ok=collect_pair(Path(sys.argv[1]).resolve(),sys.argv[2])
    print('Timeline comparison captured.' if ok else 'Incomplete diagnostic; raw evidence retained.')
    raise SystemExit(0 if ok else 2)

"""Fixed short runtime-profiler on/off diagnostic; never a product benchmark."""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
from lifetime_windows import WINDOWS, validate_window
from run_address_history import checkpoint_markers
from run_lifetime_probes import capture_probe, raw_us
from run_memory_categories import EXECUTABLE
from run_resources import collect, digest

OBSERVERS=('profiler-control','vmmap','dart-memory')


def capture_control(marker,output,mode):
    r=dict(attempt=marker['attempt'],phase=marker['phase'],tool='profiler-control',
           runId=marker['runId'],pid=marker['pid'],status='unavailable',qualified=False,startedUs=raw_us())
    path=output/f"profiler-{r['attempt']}-{r['phase']}.txt";journal=path.with_suffix('.rpc.jsonl')
    try:
        actual=subprocess.check_output(['/bin/ps','-p',str(r['pid']),'-o','comm='],text=True,timeout=2).strip()
        if actual!=str(EXECUTABLE):raise ValueError('Owned executable mismatch')
        r['command']=[sys.executable,str(Path(__file__).with_name('profiler_control.py')),
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


def collect_arm(output,flutter,arm):
    records={(n,phase,tool):dict(attempt=n,phase=phase,tool=tool,status='not_observed',qualified=False)
             for n,phase in WINDOWS for tool in OBSERVERS}
    markers={};errors=[];pid=None;done=threading.Event();collected=False
    def persist():
        if output.exists():
            (output/'profiler-probes.json').write_text(json.dumps(dict(arm=arm,records=list(records.values()),
                markers=list(markers.values()),errors=errors),indent=2)+'\n')
    def consume(capture):
        nonlocal pid
        log=output/'playback.log';defines=output/'defines.json'
        if not log.exists() or not defines.exists():return
        run=json.loads(defines.read_text())['YL_RESOURCE_RUN_ID']
        for m in checkpoint_markers(log.read_text(errors='replace')):
            if m['runId']!=run or m['schemaVersion']!=1 or (pid is not None and pid!=m['pid']):
                raise ValueError('Unexpected checkpoint identity')
            pid=m['pid'];key=(m['attempt'],m['phase']);mk=(*key,m['edge'])
            if mk in markers:
                if markers[mk]!=m:raise ValueError('Conflicting checkpoint')
                continue
            markers[mk]=m
            if m['edge']!='begin' or not capture:continue
            r=capture_control(m,output,arm if key==(1,'live') else 'observe')
            records[(*key,'profiler-control')]=r;persist()
            if r['status']!='captured' or r['control']['after']!=(arm=='on'):
                raise ValueError('Requested profiler state not verified')
            for tool in ('vmmap','dart-memory'):
                records[(*key,tool)]=capture_probe(m,tool,output,detailed=True,include_system=True);persist()
    def monitor():
        while not done.wait(.1):
            try:consume(True)
            except (OSError,ValueError,KeyError,TypeError) as e:
                errors.append(type(e).__name__);persist();return
    thread=threading.Thread(target=monitor);thread.start()
    try:collected=collect(output,flutter,profile_cycles=True,lifetime_probes=True)
    finally:done.set();thread.join();persist()
    try:
        consume(False)
        if collected:
            run=json.loads((output/'result.json').read_text())
            if len(run['observations'])!=10 or any(row['pid']!=pid or row['outcome']!='passed' for row in run['observations']):
                raise ValueError('Incomplete resource workload')
        for (n,phase,tool),r in records.items():
            r['qualified']=validate_window(markers.get((n,phase,'begin')),markers.get((n,phase,'end')),r)
        controls=[records[(n,phase,'profiler-control')] for n,phase in WINDOWS]
        if all(r['qualified'] for r in controls):
            if len({json.dumps(r['control']['vmIdentity'],sort_keys=True) for r in controls})!=1:raise ValueError('VM group identity changed')
    except (OSError,ValueError,KeyError,TypeError) as e:errors.append(type(e).__name__)
    result=dict(arm=arm,pid=pid,resourceRunCollected=collected,markers=list(markers.values()),
        records=list(records.values()),errors=errors,
        complete=collected and not errors and all(r['qualified'] for r in records.values()),
        performanceBaseline=False,budgetAdmission=False,leakVerdict=None)
    if collected and EXECUTABLE.is_file():
        result['appExecutable']=dict(path=str(EXECUTABLE),sha256=digest(EXECUTABLE))
    if output.exists():(output/'profiler-probes.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


def collect_pair(output,flutter):
    if any(k.startswith('MallocStackLogging') for k in os.environ):raise ValueError('Stack logging must be absent')
    raw_us();output.mkdir(parents=True,exist_ok=False)
    protocol=dict(schemaVersion=1,purpose='short-runtime-profiler-control',armOrder=['on','off'],
        plannedAttemptsPerArm=10,windows=WINDOWS,checkpointSeconds=20,observers=OBSERVERS,
        intervention='getVM/getFlagList/setFlag(profiler)/getFlagList/getVM at live-1; read-only at disposed-2/8',
        startupProfiler='unchanged; runtime intervention after first player load',
        vmIdentity='exact PID plus application/system group IDs; raw VM startTime retained without equality gate',
        observerTimeoutSeconds=10,rpcReadTimeoutSeconds=2,forcedGC=False,stackLogging=False,
        cacheState='os-cache-uncontrolled',scriptSha256=digest(Path(__file__)),flutter=flutter,
        performanceBaseline=False,budgetAdmission=False,leakVerdict=None)
    (output/'protocol.json').write_text(json.dumps(protocol,indent=2)+'\n')
    arms=[];matched=False;errors=[]
    for arm in protocol['armOrder']:
        arms.append(collect_arm(output/arm,flutter,arm))
        (output/'comparison.json').write_text(json.dumps(dict(arms=arms,complete=False),indent=2)+'\n')
    if all(a['complete'] for a in arms):
        runs=[json.loads((output/arm/'result.json').read_text()) for arm in protocol['armOrder']]
        # Dylib install names include each fresh output path; its source is in sourceHash.
        fields=('sourceHash','dependencies','artifactFingerprints','mediaHash','device','architecture','buildMode','plannedAttempts','protocol')
        matched=all(runs[0][k]==runs[1][k] for k in fields) and arms[0]['pid']!=arms[1]['pid']
        if not matched:errors.append('Independent matched identity unavailable')
    result=dict(schemaVersion=1,protocolSha256=digest(output/'protocol.json'),arms=arms,
        matchedConditions=matched,errors=errors,complete=matched and all(a['complete'] for a in arms),
        performanceBaseline=False,budgetAdmission=False,leakVerdict=None)
    (output/'comparison.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['complete']


if __name__=='__main__':
    if len(sys.argv)!=3:raise SystemExit('Usage: run_profiler_comparison.py NEW_DIRECTORY FLUTTER_EXECUTABLE')
    ok=collect_pair(Path(sys.argv[1]).resolve(),sys.argv[2])
    print('Runtime profiler comparison captured.' if ok else 'Incomplete comparison; raw evidence retained.')
    raise SystemExit(0 if ok else 2)

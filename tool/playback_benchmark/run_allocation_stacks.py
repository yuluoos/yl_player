"""Bounded complete allocation trees to resolve stack-derived non-object names."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
from lifetime_windows import WINDOWS, validate_window
from run_address_history import checkpoint_markers, launch
from run_lifetime_probes import capture_probe, raw_us
from run_memory_categories import EXECUTABLE
from run_profiler_comparison import capture_control
from run_resources import collect, digest

OBSERVERS=('profiler-control','heap','allocation-tree')


def capture_tree(marker,output):
    r=dict(attempt=marker['attempt'],phase=marker['phase'],tool='allocation-tree',
           runId=marker['runId'],pid=marker['pid'],status='unavailable',qualified=False,startedUs=raw_us())
    path=output/f"allocation-tree-{r['attempt']}-{r['phase']}.txt"
    try:
        actual=subprocess.check_output(['/bin/ps','-p',str(r['pid']),'-o','comm='],text=True,timeout=2).strip()
        if actual!=str(EXECUTABLE):raise ValueError('Owned executable mismatch')
        r['command']=['/usr/bin/malloc_history',str(r['pid']),'-callTree','-noContent','-invert','-ignoreThreads','.*']
        with path.open('w') as stream:
            p=subprocess.run(r['command'],stdout=stream,stderr=stream,timeout=8)
        r['exitCode']=p.returncode
        text=path.read_text()
        identity=re.search(r'^Process: +yl_player_example \['+str(r['pid'])+r'\] *$',text,re.M)
        body=text.partition('Call graph:\n')[2].partition('Binary Images:')[0]
        rows=[line for line in body.splitlines() if line.strip() and not line.startswith('Total number in stack')]
        r['stackRowsPresent']=any(re.search(r'\b[0-9]+\b',line) for line in rows)
        # Nonempty output still does not establish complete stack coverage or ownership.
        r['status']='captured' if p.returncode==0 and identity and r['stackRowsPresent'] and text.startswith('malloc_history Report Version:  2.0\n') else 'failed'
    except (OSError,ValueError,subprocess.SubprocessError) as e:r['errorType']=type(e).__name__
    finally:
        r['endedUs']=raw_us()
        if path.exists():r['raw']=dict(file=path.name,sha256=digest(path),bytes=path.stat().st_size)
    return r


def collect_stacks(output,flutter):
    if any(k.startswith('MallocStackLogging') for k in os.environ):raise ValueError('Inherited stack logging must be absent')
    raw_us();output.mkdir(parents=True,exist_ok=False)
    run_output=output/'run';wrapper=output/'flutter-stacks'
    wrapper.write_text('#!'+sys.executable+'\nimport os,sys\nos.execv('+repr(sys.executable)+','+
                       repr([sys.executable,str(Path(__file__).resolve()),'--launch',flutter])+'+sys.argv[1:])\n')
    wrapper.chmod(0o700)
    protocol=dict(schemaVersion=1,purpose='short-profiler-off-allocation-trees-v2',plannedAttempts=10,
        windows=WINDOWS,checkpointSeconds=20,observers=OBSERVERS,classSelection='.*',
        treeOptions=['-callTree','-noContent','-invert','-ignoreThreads'],treeTimeoutSeconds=8,
        controlTimeoutSeconds=10,heapTimeoutSeconds=10,forcedGC=False,
        profilerIntervention='off at live-1 after first load; read-only at disposed-2/8',
        launchEnvironment=dict(MallocStackLogging='full',MallocStackLoggingNoCompact='1'),
        scriptSha256=digest(Path(__file__)),launcherSha256=digest(Path(__file__).with_name('run_address_history.py')),
        wrapperSha256=digest(wrapper),performanceBaseline=False,budgetAdmission=False,leakVerdict=None)
    (output/'protocol.json').write_text(json.dumps(protocol,indent=2)+'\n')
    records={(n,phase,tool):dict(attempt=n,phase=phase,tool=tool,status='not_observed',qualified=False)
             for n,phase in WINDOWS for tool in OBSERVERS}
    markers={};errors=[];pid=None;done=threading.Event();collected=False
    def persist():
        (output/'allocation-probes.json').write_text(json.dumps(dict(records=list(records.values()),
            markers=list(markers.values()),errors=errors),indent=2)+'\n')
    def consume(capture):
        nonlocal pid
        log=run_output/'playback.log';defines=run_output/'defines.json'
        if not log.exists() or not defines.exists():return
        run=json.loads(defines.read_text())['YL_RESOURCE_RUN_ID']
        for m in checkpoint_markers(log.read_text(errors='replace')):
            if m['runId']!=run or m['schemaVersion']!=1 or (pid is not None and pid!=m['pid']):
                raise ValueError('Unexpected checkpoint identity')
            pid=m['pid'];key=(m['attempt'],m['phase']);mk=(*key,m['edge'])
            if mk in markers:
                if markers[mk]!=m:raise ValueError('Conflicting marker')
                continue
            markers[mk]=m
            if m['edge']!='begin' or not capture:continue
            r=capture_control(m,run_output,'off' if key==(1,'live') else 'observe')
            records[(*key,'profiler-control')]=r;persist()
            if r['status']!='captured' or r['control']['after'] is not False:
                raise ValueError('Profiler-off state not verified')
            records[(*key,'heap')]=capture_probe(m,'heap',run_output);persist()
            records[(*key,'allocation-tree')]=capture_tree(m,run_output);persist()
    def monitor():
        while not done.wait(.1):
            try:consume(True)
            except (OSError,ValueError,KeyError,TypeError) as e:
                errors.append(type(e).__name__);persist();return
    thread=threading.Thread(target=monitor);thread.start()
    try:collected=collect(run_output,str(wrapper),profile_cycles=True,lifetime_probes=True,allocation_stacks=True)
    finally:done.set();thread.join();persist()
    try:
        consume(False)
        if collected:
            run=json.loads((run_output/'result.json').read_text())
            if len(run['observations'])!=10 or any(row['pid']!=pid or row['outcome']!='passed' for row in run['observations']):
                raise ValueError('Incomplete resource workload')
        for (n,phase,tool),r in records.items():
            r['qualified']=validate_window(markers.get((n,phase,'begin')),markers.get((n,phase,'end')),r)
        controls=[records[(n,phase,'profiler-control')] for n,phase in WINDOWS]
        if all(r['qualified'] for r in controls):
            if len({json.dumps(r['control']['vmIdentity'],sort_keys=True) for r in controls})!=1:raise ValueError('VM group identity changed')
    except (OSError,ValueError,KeyError,TypeError) as e:errors.append(type(e).__name__)
    result=dict(schemaVersion=1,pid=pid,resourceRunCollected=collected,markers=list(markers.values()),
        records=list(records.values()),errors=errors,protocolSha256=digest(output/'protocol.json'),
        complete=collected and not errors and all(r['qualified'] for r in records.values()),
        allocationOwnershipVerified=False,performanceBaseline=False,budgetAdmission=False,leakVerdict=None)
    if collected and EXECUTABLE.is_file():result['appExecutable']=dict(path=str(EXECUTABLE),sha256=digest(EXECUTABLE))
    (output/'allocation-probes.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['complete']


if __name__=='__main__':
    args=sys.argv[1:]
    if args and args[0]=='--launch':launch(args[1],args[2:])
    elif len(args)==2:
        ok=collect_stacks(Path(args[0]).resolve(),args[1])
        print('Allocation trees captured.' if ok else 'Incomplete diagnostic; raw evidence retained.')
        raise SystemExit(0 if ok else 2)
    else:raise SystemExit('Usage: run_allocation_stacks.py NEW_DIRECTORY FLUTTER_EXECUTABLE')

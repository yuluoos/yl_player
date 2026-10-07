"""Bounded own-process Untagged address history; diagnostic, never a baseline."""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
from lifetime_windows import WINDOWS, validate_marker, validate_window
from run_lifetime_probes import capture_probe, raw_us
from run_memory_categories import EXECUTABLE
from run_resources import collect, digest

OFFSETS=(0,16384,32768)
OBSERVERS=('vmmap','dart-memory',*(f'history-{n}' for n in OFFSETS))


def checkpoint_markers(text):
    for line in text.splitlines(keepends=True):
        # The logger may still be writing its last line; retry on the next poll.
        if not line.endswith('\n') or 'YL_RESOURCE_CHECKPOINT=' not in line:continue
        m=json.loads(line.split('YL_RESOURCE_CHECKPOINT=',1)[1]);validate_marker(m)
        yield m


def select_target(regions):
    candidates=[r for r in regions if r['protection']=='rw-/rwx' and r['virtualBytes']>=8*1024*1024]
    return min(candidates,key=lambda r:(-r['virtualBytes'],int(r['start'],16))) if candidates else None


def capture_history(marker,output,target,offset):
    r=dict(attempt=marker['attempt'],phase=marker['phase'],tool=f'history-{offset}',
           runId=marker['runId'],pid=marker['pid'],status='unavailable',qualified=False,startedUs=raw_us())
    path=output/f"history-{r['attempt']}-{r['phase']}-{offset}.txt"
    try:
        if target is None:raise ValueError('No eligible live target')
        actual=subprocess.check_output(['/bin/ps','-p',str(r['pid']),'-o','comm='],text=True,timeout=2).strip()
        if actual!=str(EXECUTABLE):raise ValueError('Owned executable mismatch')
        r['address']=hex(int(target['start'],16)+offset)
        r['command']=['/usr/bin/malloc_history',str(r['pid']),'-fullStacks',r['address']]
        with path.open('w') as stream:
            process=subprocess.run(r['command'],stdout=stream,stderr=stream,timeout=2)
        r['exitCode']=process.returncode
        # Captured means bounded tool output, NOT a successful allocation/free match.
        r['status']='captured' if process.returncode==0 and path.read_text().startswith('malloc_history Report Version:  2.0\n') else 'failed'
    except (OSError,ValueError,subprocess.SubprocessError) as e:r['errorType']=type(e).__name__
    finally:
        r['endedUs']=raw_us()
        if path.exists():r['raw']=dict(file=path.name,sha256=digest(path),bytes=path.stat().st_size)
    return r


def launch(flutter,args):
    if not args or args[0]!='drive':raise ValueError('Expected owned profile driver')
    defines=next(a for a in args if a.startswith('--dart-define-from-file='))
    target=next(a for a in args if a.startswith('--target='))
    subprocess.run([flutter,'build','macos','--profile','--no-pub',defines,target],check=True,timeout=300)
    env=dict(os.environ,MallocStackLogging='full',MallocStackLoggingNoCompact='1')
    app=Path.cwd()/'build/macos/Build/Products/Profile/yl_player_example.app'
    os.execve(flutter,[flutter,*args,'--use-application-binary='+str(app)],env)


def collect_history(output,flutter):
    raw_us()
    output.mkdir(parents=True,exist_ok=False)
    run_output=output/'run'
    wrapper=output/'flutter-history'
    wrapper.write_text('#!'+sys.executable+'\nimport os,sys\nos.execv('+repr(sys.executable)+','+
                       repr([sys.executable,str(Path(__file__).resolve()),'--launch',flutter])+'+sys.argv[1:])\n')
    wrapper.chmod(0o700)
    protocol=dict(schemaVersion=1,purpose='short-untagged-address-history',plannedAttempts=10,
        windows=WINDOWS,checkpointSeconds=20,observers=OBSERVERS,
        targetSelection='largest live-1 Untagged rw-/rwx >=8MiB, tie lowest address; reused query addresses only',
        offsets=OFFSETS,historyQueryTimeoutSeconds=2,vmProbeTimeoutSeconds=10,
        vmMemoryScope='application-and-system-isolate-groups',forcedGC=False,
        launchEnvironment=dict(MallocStackLogging='full',MallocStackLoggingNoCompact='1'),
        scriptSha256=digest(Path(__file__)),wrapperSha256=digest(wrapper),
        performanceBaseline=False,budgetAdmission=False,leakVerdict=None)
    (output/'protocol.json').write_text(json.dumps(protocol,indent=2)+'\n')
    records={(n,phase,tool):dict(attempt=n,phase=phase,tool=tool,status='not_observed',qualified=False)
             for n,phase in WINDOWS for tool in OBSERVERS}
    markers={};errors=[];target=None;pid=None;done=threading.Event();collected=False
    def persist():
        (output/'history-probes.json').write_text(json.dumps(dict(records=list(records.values()),
            markers=list(markers.values()),errors=errors,target=target),indent=2)+'\n')
    def consume(capture):
        nonlocal target,pid
        log=run_output/'playback.log';defines=run_output/'defines.json'
        if not log.exists() or not defines.exists():return
        run=json.loads(defines.read_text())['YL_RESOURCE_RUN_ID']
        for m in checkpoint_markers(log.read_text(errors='replace')):
            if m['runId']!=run or m['schemaVersion']!=1 or (pid is not None and m['pid']!=pid):
                raise ValueError('Unexpected checkpoint identity')
            pid=m['pid'];key=(m['attempt'],m['phase']);mk=(*key,m['edge'])
            if mk in markers:
                if markers[mk]!=m:raise ValueError('Conflicting marker')
                continue
            markers[mk]=m
            if m['edge']!='begin' or not capture:continue
            for tool in ('vmmap','dart-memory'):
                r=capture_probe(m,tool,run_output,detailed=True,include_system=True)
                records[(*key,tool)]=r
                if tool=='vmmap' and key==(1,'live') and r['status']=='captured':
                    target=select_target(r['untaggedRegions'])
                persist()
            for offset in OFFSETS:
                records[(*key,f'history-{offset}')]=capture_history(m,run_output,target,offset)
                persist()
    def monitor():
        while not done.wait(.1):
            try:consume(True)
            except (OSError,ValueError,KeyError,TypeError) as e:
                errors.append(type(e).__name__);persist();return
    thread=threading.Thread(target=monitor);thread.start()
    try:collected=collect(run_output,str(wrapper),profile_cycles=True,lifetime_probes=True)
    finally:done.set();thread.join();persist()
    try:
        consume(False)
        if collected:
            run=json.loads((run_output/'result.json').read_text())
            if not run['observations'] or any(row['pid']!=pid for row in run['observations']):
                raise ValueError('Resource process mismatch')
        for (n,phase,tool),r in records.items():
            r['qualified']=validate_window(markers.get((n,phase,'begin')),markers.get((n,phase,'end')),r)
    except (OSError,ValueError,KeyError,TypeError) as e:errors.append(type(e).__name__)
    result=dict(schemaVersion=1,resourceRunCollected=collected,clock='CLOCK_MONOTONIC_RAW/microseconds',
        markers=list(markers.values()),records=list(records.values()),errors=errors,target=target,
        protocolSha256=digest(output/'protocol.json'),
        complete=collected and not errors and all(r['qualified'] for r in records.values()),
        allocationIdentityVerified=False,leakVerdict=None,performanceBaseline=False,budgetAdmission=False)
    (output/'history-probes.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['complete']


if __name__=='__main__':
    args=sys.argv[1:]
    if args and args[0]=='--launch':launch(args[1],args[2:])
    elif len(args)==2:
        ok=collect_history(Path(args[0]).resolve(),args[1])
        print('Captured bounded history.' if ok else 'Incomplete diagnostic; raw evidence retained.')
        raise SystemExit(0 if ok else 2)
    else:raise SystemExit('Usage: run_address_history.py NEW_DIRECTORY FLUTTER_EXECUTABLE')

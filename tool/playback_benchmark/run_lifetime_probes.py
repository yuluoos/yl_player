"""Capture native heap summaries in explicit live/disposed example checkpoints."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
from lifetime_windows import validate_marker, validate_window, WINDOWS, LONG_WINDOWS
from run_resources import collect, digest
from run_memory_categories import EXECUTABLE
from memory_categories import parse_vmmap
from memory_mapping import untagged_regions


def raw_us():return time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)//1000


def capture_probe(marker, tool, output, *, detailed=False, include_system=False):
    if tool not in ('heap','vmmap','dart-memory'):raise ValueError('Unknown lifetime observer')
    r=dict(attempt=marker['attempt'],phase=marker['phase'],tool=tool,
           runId=marker['runId'],pid=marker['pid'],status='unavailable',qualified=False,startedUs=raw_us())
    path=output/f"{tool}-{r['attempt']}-{r['phase']}.txt"
    journal=path.with_suffix('.rpc.jsonl')
    try:
        actual=subprocess.check_output(['/bin/ps','-p',str(r['pid']),'-o','comm='],text=True,timeout=2).strip()
        if actual!=str(EXECUTABLE):raise ValueError('Owned executable mismatch')
        command=['/usr/bin/'+tool,'--noContent' if tool=='heap' else '-summary',str(r['pid'])]
        if tool=='vmmap' and detailed:command=['/usr/bin/vmmap','-wide','-interleaved','-noCoalesce',str(r['pid'])]
        if tool=='dart-memory':command=[sys.executable,str(Path(__file__).with_name('memory_mapping.py')),str(output/'playback.log'),str(r['pid']),str(journal)]
        if tool=='dart-memory' and include_system:command.insert(2,'--include-system')
        r['command']=command
        with path.open('w') as stream:
            p=subprocess.run(command,stdout=stream,stderr=stream,timeout=10)
        r['exitCode']=p.returncode
        text=path.read_text()
        if tool=='dart-memory':
            payload=json.loads(text)
            if p.returncode==0 and payload.get('status')=='captured' and payload.get('pid')==r['pid']:
                r.update(status='captured',memory=payload['memory'])
            else:r['status']='failed'
            return r
        identity=re.search(r'^Process: +yl_player_example \['+str(r['pid'])+r'\] *$',text,re.M)
        if p.returncode==0 and identity:
            if tool=='vmmap':
                r['summary']=parse_vmmap(text,r['pid'])
                if detailed:r['untaggedRegions']=untagged_regions(text,r['pid'])
            r['status']='captured'
        else:r['status']='failed'
    except (OSError,ValueError,subprocess.SubprocessError) as e:r['errorType']=type(e).__name__
    finally:
        r['endedUs']=raw_us()
        if path.exists():r['raw']=dict(file=path.name,sha256=digest(path),bytes=path.stat().st_size)
        if tool=='dart-memory' and journal.exists():
            r['rpcJournal']=dict(file=journal.name,sha256=digest(journal),bytes=journal.stat().st_size)
    return r


def collect_lifetimes(output,flutter,*,long_cycles=False,memory_mapping=False):
    if memory_mapping and not long_cycles:raise ValueError("Memory mapping requires long-cycle windows")
    if output.exists():raise FileExistsError('Fresh output required')
    raw_us()  # Fail before starting any app if the native clock is unavailable.
    windows=LONG_WINDOWS if long_cycles else WINDOWS
    observers=('heap','vmmap','dart-memory') if memory_mapping else ('heap','vmmap') if long_cycles else ('heap',)
    done=threading.Event();markers={};errors=[];selected_pid=None
    records={(n,phase,tool):dict(attempt=n,phase=phase,tool=tool,status='not_observed',qualified=False)
             for n,phase in windows for tool in observers}
    def consume(capture):
        nonlocal selected_pid
        log=output/'playback.log';defines=output/'defines.json'
        if not log.exists() or not defines.exists():return
        run=json.loads(defines.read_text())['YL_RESOURCE_RUN_ID']
        for line in log.read_text(errors='replace').splitlines():
            if 'YL_RESOURCE_CHECKPOINT=' not in line:continue
            try:m=json.loads(line.split('YL_RESOURCE_CHECKPOINT=',1)[1])
            except ValueError:continue
            validate_marker(m)
            if m['runId']!=run or m['schemaVersion']!=(2 if long_cycles else 1):
                raise ValueError('Unexpected checkpoint run or protocol')
            if selected_pid is not None and selected_pid!=m['pid']:raise ValueError('Process changed')
            selected_pid=m['pid']
            key=(m['attempt'],m['phase']);marker_key=(*key,m['edge'])
            if marker_key in markers:
                if markers[marker_key]!=m:raise ValueError('Conflicting checkpoint')
                continue
            markers[marker_key]=m
            if m['edge']!='begin' or not capture:continue
            for tool in observers:
                records[(*key,tool)]=capture_probe(m,tool,output,detailed=memory_mapping)
                (output/'lifetime-probes.json').write_text(json.dumps(list(records.values()),indent=2)+'\n')
    def monitor():
        while not done.wait(.1):
            try:consume(True)
            except (OSError,ValueError,KeyError,TypeError) as e:
                errors.append(type(e).__name__);return
    thread=threading.Thread(target=monitor);thread.start()
    try:collected=collect(output,flutter,profile_cycles=True,lifetime_probes=not long_cycles,
                          long_lifetime_probes=long_cycles,memory_mapping=memory_mapping)
    finally:done.set();thread.join()
    try:
        consume(False)
        if collected:
            resource=json.loads((output/'result.json').read_text())
            if resource['observations'][0]['pid']!=selected_pid:raise ValueError('Resource PID mismatch')
        for (n,phase,tool),r in records.items():
            r['qualified']=validate_window(markers.get((n,phase,'begin')),markers.get((n,phase,'end')),r)
    except (OSError,ValueError,KeyError,TypeError) as e:errors.append(type(e).__name__)
    result=dict(schemaVersion=2 if long_cycles else 1,protocol='long-cycle-v1' if long_cycles else 'short-cycle-v1',memoryMapping=memory_mapping,resourceRunCollected=collected,clock='CLOCK_MONOTONIC_RAW/microseconds',
                markers=list(markers.values()),records=list(records.values()),errors=errors,
                complete=collected and not errors and all(r['qualified'] for r in records.values()),
                leakVerdict=None,performanceBaseline=False,budgetAdmission=False,
                limitation='Heap-recognized allocations only; missing classes are not proof of deallocation.')
    (output/'lifetime-probes.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['complete']


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--long-cycles',action='store_true')
    parser.add_argument('--memory-mapping',action='store_true')
    parser.add_argument('output',type=Path);parser.add_argument('flutter')
    args=parser.parse_args()
    try:ok=collect_lifetimes(args.output.resolve(),args.flutter,long_cycles=args.long_cycles,memory_mapping=args.memory_mapping)
    except (OSError,AttributeError,ValueError):
        print('Fresh output and macOS raw clock required.');return 2
    print('Lifetime checkpoints captured.' if ok else 'Lifetime evidence incomplete; raw results retained.')
    return 0 if ok else 2

if __name__=='__main__':raise SystemExit(main())

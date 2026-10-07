"""Capture native heap summaries in explicit live/disposed example checkpoints."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import threading
import time
from lifetime_windows import validate_marker, validate_window, WINDOWS
from run_resources import collect, digest
from run_memory_categories import EXECUTABLE


def raw_us():return time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)//1000


def collect_lifetimes(output,flutter):
    if output.exists():raise FileExistsError('Fresh output required')
    raw_us()  # Fail before starting any app if the native clock is unavailable.
    done=threading.Event();markers={};errors=[]
    records={key:dict(attempt=key[0],phase=key[1],status='not_observed',qualified=False) for key in WINDOWS}
    def consume(capture):
        log=output/'playback.log';defines=output/'defines.json'
        if not log.exists() or not defines.exists():return
        run=json.loads(defines.read_text())['YL_RESOURCE_RUN_ID']
        for line in log.read_text(errors='replace').splitlines():
            if 'YL_RESOURCE_CHECKPOINT=' not in line:continue
            try:m=json.loads(line.split('YL_RESOURCE_CHECKPOINT=',1)[1])
            except ValueError:continue
            validate_marker(m)
            if m['runId']!=run:raise ValueError('Unexpected checkpoint run')
            key=(m['attempt'],m['phase']);marker_key=(*key,m['edge'])
            if marker_key in markers:
                if markers[marker_key]!=m:raise ValueError('Conflicting checkpoint')
                continue
            markers[marker_key]=m
            r=records[key]
            if m['edge']!='begin' or not capture:continue
            r.update(runId=run,pid=m['pid'],status='unavailable',startedUs=raw_us())
            path=output/f'heap-{key[0]}-{key[1]}.txt'
            try:
                actual=subprocess.check_output(['/bin/ps','-p',str(m['pid']),'-o','comm='],text=True,timeout=2).strip()
                if actual!=str(EXECUTABLE):raise ValueError('Owned executable mismatch')
                command=['/usr/bin/heap','--noContent',str(m['pid'])]
                r['command']=command
                with path.open('w') as stream:
                    p=subprocess.run(command,stdout=stream,stderr=stream,timeout=10)
                r['exitCode']=p.returncode
                text=path.read_text()
                identity=re.search(r'^Process: +yl_player_example \['+str(m['pid'])+r'\] *$',text,re.M)
                r['status']='captured' if p.returncode==0 and identity else 'failed'
            except (OSError,ValueError,subprocess.SubprocessError) as e:r['errorType']=type(e).__name__
            finally:
                r['endedUs']=raw_us()
                if path.exists():r['raw']=dict(file=path.name,sha256=digest(path),bytes=path.stat().st_size)
                (output/'lifetime-probes.json').write_text(json.dumps(list(records.values()),indent=2)+'\n')
    def monitor():
        while not done.wait(.1):
            try:consume(True)
            except (OSError,ValueError,KeyError,TypeError) as e:
                errors.append(type(e).__name__);return
    thread=threading.Thread(target=monitor);thread.start()
    try:collected=collect(output,flutter,profile_cycles=True,lifetime_probes=True)
    finally:done.set();thread.join()
    try:
        consume(False)
        for key,r in records.items():
            r['qualified']=validate_window(markers.get((*key,'begin')),markers.get((*key,'end')),r)
    except (OSError,ValueError,KeyError,TypeError) as e:errors.append(type(e).__name__)
    result=dict(schemaVersion=1,resourceRunCollected=collected,clock='CLOCK_MONOTONIC_RAW/microseconds',
                markers=list(markers.values()),records=list(records.values()),errors=errors,
                complete=collected and not errors and all(r['qualified'] for r in records.values()),
                leakVerdict=None,performanceBaseline=False,budgetAdmission=False,
                limitation='Heap-recognized allocations only; missing classes are not proof of deallocation.')
    (output/'lifetime-probes.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['complete']


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path);parser.add_argument('flutter')
    args=parser.parse_args()
    try:ok=collect_lifetimes(args.output.resolve(),args.flutter)
    except (OSError,AttributeError):
        print('Fresh output and macOS raw clock required.');return 2
    print('Lifetime checkpoints captured.' if ok else 'Lifetime evidence incomplete; raw results retained.')
    return 0 if ok else 2

if __name__=='__main__':raise SystemExit(main())

"""Observe only this runner's profile process after cycles 2, 5, 8.

vmmap may pause/perturb the process. These are diagnostic snapshots, not baseline
samples, and may overlap the next cycle. No forced GC or allocation-stack logging.
"""
import argparse
import json
from pathlib import Path
import subprocess
import threading
import time
from memory_categories import parse_vmmap, probe_identity
from run_resources import collect, digest, EXAMPLE

ATTEMPTS = (2,5,8)
EXECUTABLE = EXAMPLE/'build/macos/Build/Products/Profile/yl_player_example.app/Contents/MacOS/yl_player_example'


def collect_categories(output, flutter, *, harness_only):
    done=threading.Event()
    records={n:dict(attempt=n,status='not_observed') for n in ATTEMPTS}
    workload='harness-only' if harness_only else 'playback'
    monitor_errors=[]

    def monitor():
        selected_pid=None
        while not done.wait(.1):
            try:
                log=output/'playback.log';defines=output/'defines.json'
                if not log.exists() or not defines.exists():continue
                run_id=json.loads(defines.read_text())['YL_RESOURCE_RUN_ID']
                lines=log.read_text(errors='replace').splitlines()
                for line in lines:
                    if 'YL_RESOURCE_SERIES=' not in line:continue
                    try:row=json.loads(line.split('YL_RESOURCE_SERIES=',1)[1])
                    except ValueError:continue  # Writer may not have finished this line.
                    n,pid=probe_identity(row,run_id,workload)
                    if n not in ATTEMPTS or records[n]['status']!='not_observed':continue
                    r=records[n]
                    r.update(status='unavailable',pid=pid,runId=run_id,hostStartedNs=time.monotonic_ns())
                    raw=output/f'vmmap-{n}.txt'
                    try:
                        if selected_pid is not None and selected_pid!=pid:
                            raise ValueError('Process changed')
                        selected_pid=pid
                        actual=subprocess.check_output(['/bin/ps','-p',str(pid),'-o','comm='],text=True,timeout=2).strip()
                        if actual!=str(EXECUTABLE):raise ValueError('Owned executable mismatch')
                        command=['/usr/bin/vmmap','-summary',str(pid)]
                        r['command']=command
                        with raw.open('w') as stream:
                            result=subprocess.run(command,stdout=stream,stderr=stream,timeout=10)
                        r['exitCode']=result.returncode
                        if result.returncode==0:
                            r['summary']=parse_vmmap(raw.read_text(),pid)
                            r['status']='captured'
                        else:r['status']='failed'
                    except (OSError,ValueError,subprocess.SubprocessError) as error:
                        r['errorType']=type(error).__name__
                    finally:
                        r['hostEndedNs']=time.monotonic_ns()
                        if raw.exists():r['raw']=dict(file=raw.name,sha256=digest(raw),bytes=raw.stat().st_size)
                        (output/'category-probes.json').write_text(json.dumps(list(records.values()),indent=2)+'\n')
            except (OSError,ValueError,KeyError,TypeError) as error:
                monitor_errors.append(type(error).__name__)
                return  # Fail closed; never inspect an uncertain target.

    # collect owns creation of this fresh directory; avoid touching an old run.
    if output.exists():raise FileExistsError('A fresh output directory is required')
    thread=threading.Thread(target=monitor)
    thread.start()
    try:collected=collect(output,flutter,profile_cycles=True,harness_only=harness_only)
    finally:
        done.set()
        thread.join()  # All nested commands have a bounded deadline.
    result=dict(schemaVersion=1,workload=workload,plannedProbeAttempts=list(ATTEMPTS),
        resourceRunCollected=collected,records=list(records.values()),monitorErrors=monitor_errors,
        observationBoundary='after trial log receipt; may overlap next cycle',
        observer='vmmap -summary; may perturb target',performanceBaseline=False,budgetAdmission=False,leakVerdict=None)
    result['complete']=collected and not monitor_errors and all(r['status']=='captured' for r in records.values())
    (output/'category-probes.json').write_text(json.dumps(result,indent=2)+'\n')
    return result['complete']


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workload',choices=('harness-only','playback'))
    parser.add_argument('output',type=Path)
    parser.add_argument('flutter')
    args=parser.parse_args()
    try:ok=collect_categories(args.output.resolve(),args.flutter,harness_only=args.workload=='harness-only')
    except OSError:
        print('Fresh writable output required; existing evidence unchanged.');return 2
    print('Memory category diagnostics captured.' if ok else 'Memory category diagnostics incomplete; evidence retained.')
    return 0 if ok else 2

if __name__=='__main__':raise SystemExit(main())

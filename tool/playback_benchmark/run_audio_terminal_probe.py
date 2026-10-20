"""Independent real-ledger/tail experiment. Owned budget != total downstream memory."""
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
from run_audio_callback_roots import digest

ROOT=Path(__file__).resolve().parents[2]
BENCH=Path(__file__).parent
sys.path.insert(0, str(ROOT))
from tool.media_delivery.native_build import build_modules
CORE_SHARED = ROOT/'packages/yl_player_media_core/darwin/yl_player_media_core/Sources/yl_player_media_core'
SHARED=ROOT/'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared'
SCENARIOS=('single','pausedEOF','refill')


def phases(scenario):
    return ['configured']+(['holding200','holding2000'] if scenario=='refill' else [])+['observed','disposed']


def validate_rows(rows,scenario,pid):
    target=2000 if scenario=='refill' else 3 if scenario=='pausedEOF' else 1
    if [r['phase'] for r in rows] != phases(scenario): raise ValueError('Missing checkpoint')
    for row in rows:
        if (row['scenario'],row['pid'])!=(scenario,pid): raise ValueError('Identity mismatch')
        phase=row['phase'];hold=phase.startswith('holding');done=phase in ('observed','disposed')
        n=int(phase[7:]) if hold else target if done else 0
        count=n if done else max(0,n-1)
        events=row['events'];submits=row['submissions']
        if row['accepted']!=n or [s['ordinal'] for s in submits]!=list(range(1,count+1)) or sorted(e['ordinal'] for e in events)!=list(range(1,count+1)):
            raise ValueError('Missing/duplicate/wrong buffer identity')
        for s in submits:
            if s['frames']!=1024 or s['terminal']!=(done and s['ordinal']==target): raise ValueError('Wrong real tail')
        for e in events:
            if e['terminal']!=(done and e['ordinal']==target) or e['rawUs']<submits[e['ordinal']-1]['rawUs']:
                raise ValueError('Wrong notification/time')
        pending=1 if hold else 0
        if tuple(row[k] for k in ('pending','pendingBytes','pendingDurationUs','ledgerBytes','timelineUs','alivePCM')) != (pending,pending*8192,pending*21333,pending*8192,pending*21333,pending):
            raise ValueError('Wrong held/released ownership or real ledger')
        if row['drained']!=(phase=='observed') or row['inputFinished']!=(phase=='observed'):
            raise ValueError('Premature output drain/EOF')
        if not 0<=row['peakCount']<=24: raise ValueError('Count bound')
        if not row['ledgerBytes']<=row['ledgerPeak']<=196608: raise ValueError('Transient ledger peak')
        eof_times=[a['rawUs'] for a in row['actions'] if a['name']=='EOF']
        for s in row['samples']:
            if not (0<=s['pending']<=24 and 0<=s['bytes']<=196608 and 0<=s['ledgerBytes']<=196608 and 0<=s['durationUs']<=511992):
                raise ValueError('Reservation bound')
            if s['drained'] and (not done or s['rawUs']<max(e['rawUs'] for e in events) or len(eof_times)!=1 or s['rawUs']<eof_times[0]):
                raise ValueError('Drained before authentic notifications')
        if phase=='observed':
            eof=[a for a in row['actions'] if a['name']=='EOF']
            if len(eof)!=1 or not row['samples'] or not row['samples'][-1]['drained']:
                raise ValueError('Missing EOF/final observed drain')
            if eof[0]['rawUs']>row['samples'][-1]['rawUs']: raise ValueError('EOF after drain observation')
            if scenario=='pausedEOF':
                play=[a for a in row['actions'] if a['name']=='play']
                paused=[s for s in row['samples'] if not s['playing']]
                if eof[0]['playing'] or len(play)!=1 or not paused or any(s['drained'] for s in paused):
                    raise ValueError('Paused EOF not exercised')
                if eof[0]['rawUs']>=play[0]['rawUs'] or any(e['rawUs']<play[0]['rawUs'] for e in events):
                    raise ValueError('Notifications before resume')
    return dict(buffers=target,terminalCallbacks=1,ordinaryCallbacks=target-1,
        peakCount=rows[-2]['peakCount'],samples=len(rows[-2]['samples']))


def collect(output):
    output=output.resolve();output.mkdir(parents=True,exist_ok=False)
    source_dir=output/'sources';source_dir.mkdir()
    production=[SHARED/'Audio/YlAudioCompletionGroup.swift',CORE_SHARED/'FFmpeg/YlManagedBufferLedger.swift',CORE_SHARED/'FFmpeg/YlBoundedBufferPlan.swift']
    local=[BENCH/name for name in ('run_audio_terminal_probe.py','audio_terminal_probe.swift','AudioTerminalBudgetPrototype.swift',
        'audio_terminal_support.swift','test_audio_terminal_probe.py','run_audio_callback_roots.py')]
    sources=production+local
    for source in sources:(source_dir/source.name).write_bytes(source.read_bytes())
    main=source_dir/'main.swift';main.write_bytes((source_dir/'audio_terminal_probe.swift').read_bytes())
    binary=output/'audio_terminal_probe'
    native = build_modules(output/'native', include_delivery=False)
    compile_sources = [main, source_dir/'YlAudioCompletionGroup.swift', source_dir/'AudioTerminalBudgetPrototype.swift']
    for source_file in compile_sources:
        source_file.write_text('@testable import yl_player_media_core\n' + source_file.read_text())
    command=['xcrun','swiftc','-g',*native.flags,*map(str,compile_sources),'-o',str(binary)]
    with (output/'build.log').open('w') as log:subprocess.run(command,stdout=log,stderr=log,check=True,timeout=120)
    protocol=dict(version=1,scenarios=SCENARIOS,phases={s:phases(s) for s in SCENARIOS},
        sources={s.name:digest(s) for s in sources},binarySha256=digest(binary),buildCommand=command,
        frames=1024,sampleRate=48000,channels=2,maxCount=24,maxBytes=196608,maxDurationUs=511992,
        refillCheckpoints=[200,2000],environment={'MallocStackLogging':'full','MallocStackLoggingNoCompact':'1'},
        checkpointTimeoutSeconds=75,probeTimeoutSeconds=8,
        admission='Exact submissions/notifications, one charged PCM at held checkpoints, actual ledger bounds, EOF plus terminal callback before drain',
        retentionHypothesis='No per-buffer completion shells at held checkpoints; only one final shell after EOF',
        productionAdmission=False,downstreamBoundProven=False,
        limitations=['One held PCM waits indefinitely during starvation until next PCM or EOF',
            'Ledger bounds owned PCM/upstream timeline, not undocumented engine/device allocations',
            'Real core ledger module, no renderer clock integration',
            'MSL and heap-at-starvation disturb playback; not continuity/physical AV/longplay acceptance',
            'No mid-playback pause, real route/rate/seek or device/minimum-OS/iOS matrix'])
    (output/'protocol.json').write_text(json.dumps(protocol,indent=2)+'\n')
    result=dict(complete=False,productionAdmission=False,downstreamBoundProven=False,arms=[])
    def save():(output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    save()
    for scenario in SCENARIOS:
        folder=output/scenario;folder.mkdir();arm=dict(scenario=scenario,status='running',probes=[])
        result['arms'].append(arm);save();rows=[]
        with (folder/'stderr.txt').open('w') as stderr:
            proc=subprocess.Popen([str(binary),scenario],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,
                text=True,env=dict(os.environ,**protocol['environment']))
            selector=selectors.DefaultSelector();selector.register(proc.stdout,selectors.EVENT_READ);arm['pid']=proc.pid
            try:
                for phase in phases(scenario):
                    if not selector.select(75):raise TimeoutError('Missing checkpoint '+phase)
                    line=proc.stdout.readline();(folder/(phase+'.json')).write_text(line);row=json.loads(line);rows.append(row)
                    if (row['pid'],row['scenario'],row['phase'])!=(proc.pid,scenario,phase):raise ValueError('Wrong checkpoint')
                    actual=subprocess.check_output(['/bin/ps','-p',str(proc.pid),'-o','comm='],text=True,timeout=2).strip()
                    if actual!=str(binary):raise ValueError('Owned executable mismatch')
                    probe=dict(phase=phase,status='pending');arm['probes'].append(probe);save()
                    path=folder/(phase+'-heap.txt')
                    with path.open('w') as log:
                        child=subprocess.run(['/usr/bin/heap','--noContent',str(proc.pid)],stdout=log,stderr=log,timeout=8)
                    raw=path.read_text();match=re.search(r'^\s*(\d+)\s+(\d+)\s+[\d.]+\s+dispatch_source_t\s',raw,re.M)
                    identity=f'audio_terminal_probe [{proc.pid}]' in raw
                    probe.update(status='captured' if child.returncode==0 and match and identity else 'failed',exitCode=child.returncode,
                        sha256=digest(path),bytes=path.stat().st_size,dispatchSources=int(match[1]) if match else None)
                    save();proc.stdin.write('continue\n');proc.stdin.flush()
                arm['observation']=validate_rows(rows,scenario,proc.pid)
                arm['exitCode']=proc.wait(timeout=5)
                arm['status']='complete' if arm['exitCode']==0 and all(p['status']=='captured' for p in arm['probes']) else 'failed'
            except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as error:
                arm.update(status='failed',error=repr(error))
            finally:
                if proc.poll() is None:proc.kill();proc.wait(timeout=5)
                selector.close();proc.stdin.close();proc.stdout.close();arm.update(exitCode=proc.returncode,processExited=True);save()
    result['complete']=all(a['status']=='complete' for a in result['arms']);save()
    return result['complete']


if __name__=='__main__':sys.exit(0 if collect(Path(sys.argv[1])) else 1)

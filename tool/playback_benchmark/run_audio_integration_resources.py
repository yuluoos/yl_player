"""Independent post-EOF resource acquisition; never continuous-playback proof."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
PHASES = ('configured', 'drained', 'disposed')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def capture_heap(pid, path, run=subprocess.run):
    path = Path(path)
    result = dict(exitCode=None, valid=False, startedUptime=time.monotonic())
    try:
        with path.open('w') as stream:
            child = run(['/usr/bin/heap', '--noContent', str(pid)], stdout=stream,
                        stderr=subprocess.STDOUT, timeout=8)
        result['exitCode'] = child.returncode
    except (OSError, subprocess.SubprocessError) as error:
        result['error'] = repr(error)
    raw = path.read_text() if path.exists() else ''
    owned = bool(re.search(r'^Process:\s+yl_player_example \[' + str(pid) + r'\]', raw, re.M))
    header = re.search(r'^\s*COUNT\s+BYTES\s+AVG\s+CLASS_NAME\s+TYPE\s+BINARY', raw, re.M)
    summaries = re.findall(r'^All zones:\s+(\d+) nodes \((\d+) bytes\)\s*$', raw, re.M)
    entries = re.findall(r'^\s*(\d+)\s+(\d+)\s+[\d.]+\s+\S+', raw[header.end():] if header else '', re.M)
    summary_totals = [int(x) for x in summaries[0]] if len(summaries) == 1 else None
    table_totals = [sum(int(row[i]) for row in entries) for i in (0, 1)]
    complete_table = bool(header and entries and summary_totals == table_totals)
    result.update(endedUptime=time.monotonic(), bytes=path.stat().st_size if path.exists() else 0,
                  sha256=digest(path) if path.exists() else None, ownedPID=owned,
                  hasTable=complete_table, summaryTotals=summary_totals, tableTotals=table_totals)
    result['valid'] = result['exitCode'] == 0 and 'error' not in result and owned and result['hasTable']
    return result


def validate_rows(rows, candidate, count=2000):
    def require(condition, message):
        if not condition:
            raise ValueError(message)
    require(bool(rows), 'Missing observations')
    require(len({(r['pid'], r['generation']) for r in rows}) == 1, 'PID/generation changed')
    require(all(r['candidate'] == candidate and r['captureAfterDrain'] for r in rows), 'Wrong arm/mode')
    require(all(not r['failures'] and r['marker']['errors'] == 0 and r['marker']['interiorZeroFrames'] == 0 for r in rows), 'Sticky playback/frame error')
    require(all(0 <= r[k] <= 196608 for r in rows for k in ('ledgerBytes', 'ownedBytes', 'ledgerPeak')), 'Budget violation')
    require(all(b['uptime'] > a['uptime'] for a,b in zip(rows, rows[1:])), 'Nonmonotonic observations')
    checkpoints = [r for r in rows if r['phase'] != 'playing']
    require([r['phase'] for r in checkpoints] == ['configured','drained','disposed','disposedLater'], 'Missing/duplicate phases or live heap request')
    require(all(not r['nativePlaying'] for r in checkpoints), 'Heap while native player active')
    require(all(r['nativePlaying'] and r['pending'] for r in rows if r['phase']=='playing'), 'Playback stopped')
    _, drained, disposed, later = checkpoints
    require(all(r['marker']['frames'] == count*1024 and not r['pending'] and r['ledgerBytes'] == 0 and r['ownedBytes'] == 0 for r in (drained,disposed,later)), 'Missing frames/drain/release')
    require(later['uptime'] - disposed['uptime'] >= 2, 'Missing delayed release observation')
    expected = dict(renderedSubmissions=count-1 if candidate else 0, renderedCallbacks=count-1 if candidate else 0,
                    playedSubmissions=1 if candidate else count, playedCallbacks=1 if candidate else count)
    require(later['modes'] == expected, 'Wrong callback/submission totals')
    return dict(buffers=count, frames=later['marker']['frames'], interiorZeroFrames=0,
                ledgerPeak=max(r['ledgerPeak'] for r in rows), liveHeapProof=False,
                continuousLongPlaybackProof=False)


def eligible_decoded_checkpoint(row):
    phase = row['phase']
    return (phase in PHASES and not row['nativePlaying'] and
            (phase == 'configured' or (row['completed'] == 1 and
             not row['pending'] and row['ownedBytes'] == 0)))


def validate_decoded_rows(rows, candidate, expected_seconds=None, expected_fixture=None, callback_wrapping='wrapped'):
    def require(condition, message):
        if not condition:
            raise ValueError(message)
    require(callback_wrapping in ('wrapped','transparent'), 'Unknown callback wrapping')
    require(all(r.get('callbackWrapping','wrapped') == callback_wrapping for r in rows), 'Wrong callback wrapping')
    if callback_wrapping=='transparent':
        require(all(r.get('callbackObservation')=='unobserved' for r in rows), 'Missing unobserved callback declaration')
        require(all(r['modes']['playedCallbacks'] is None and r['modes']['renderedCallbacks'] is None for r in rows), 'Transparent counts must be null')
    else:
        require(all(r.get('callbackObservation','native-wrapped')=='native-wrapped' for r in rows), 'Wrong wrapped callback declaration')
    require([r['phase'] for r in rows] == ['configured', 'completed', 'drained', 'disposed', 'disposedLater'], 'Wrong decoded phases')
    require(len({(r['pid'], r['sessionId']) for r in rows}) == 1, 'Decoded identity changed')
    require(all(r['candidate'] == candidate and not r['failures'] for r in rows), 'Wrong arm or playback failure')
    require(all(b['uptime'] > a['uptime'] for a, b in zip(rows, rows[1:])), 'Nonmonotonic decoded observations')
    require(all(eligible_decoded_checkpoint(r) for r in rows if r['phase'] in PHASES), 'Unsafe heap checkpoint')
    require(rows[0]['completed'] == 0, 'Already completed before play')
    require(all(r['submissionAnchor'] == candidate for r in rows[:3]), 'Candidate fell back before drain')
    for row in rows[1:]:
        require(row['completed'] == 1 and row['firstFrames'] == 1 and not row['pending'] and row['ownedBytes'] == 0, 'Incomplete natural EOF')
        modes = row['modes']
        require(modes == rows[1]['modes'], 'Callbacks changed after completion')
        if callback_wrapping=='wrapped':
            require(modes['playedSubmissions'] == modes['playedCallbacks'] and modes['renderedSubmissions'] == modes['renderedCallbacks'], 'Missing native callbacks')
        require((modes['playedSubmissions'] == 1 and modes['renderedSubmissions'] > 1) if candidate else (modes['playedSubmissions'] > 1 and modes['renderedSubmissions'] == 0), 'Wrong native submission modes')
    require(all(not r['nativePlaying'] and not r['engineRunning'] and r['ledgerBytes'] == 0 for r in rows[-2:]), 'Incomplete close release')
    require(rows[-1]['uptime'] - rows[-2]['uptime'] >= 2, 'Missing delayed release')
    if expected_seconds is not None:
        require(all(r['fixtureName'] == expected_fixture for r in rows), 'Wrong length fixture')
        require(all(r['retainedDeltaCount'] == 0 and r['retainedOrderCount'] == 0 and
                    0 <= r['retainedEventCount'] <= 32 for r in rows), 'Unbounded resource recorder')
        require(expected_seconds - .5 <= rows[1]['playbackElapsedSeconds'] <= expected_seconds + 10,
                'Wrong measured playback length')
    return dict(nativeCallbackCountsObserved=callback_wrapping=='wrapped',
                playbackElapsedSeconds=rows[1].get('playbackElapsedSeconds'),
                modes=rows[1]['modes'], completedPublications=1, liveHeapProof=False,
                continuousLongPlaybackProof=False, downstreamBoundProven=False)


def freeze(out, products, extra_files=()):
    shared = ROOT/'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared'
    files = list(shared.rglob('*.swift')) + list((ROOT/'packages/yl_player/example/macos/RunnerTests').rglob('*.swift')) + [ROOT/p for p in (
        'packages/yl_player/example/macos/Flutter/ephemeral/Flutter-Generated.xcconfig',
        'tool/playback_benchmark/audio-postdrain-resources-protocol.md',
        'tool/playback_benchmark/run_audio_integration_resources.py',
        'tool/playback_benchmark/test_audio_integration_resources.py',
        'tool/playback_benchmark/test_decoded_eof_resources.py',
        'tool/playback_benchmark/decoded-callback-wrapper-protocol.md',
        'tool/playback_benchmark/summarize_callback_wrappers.py',
        'tool/playback_benchmark/test_callback_wrappers.py',
        'tool/playback_benchmark/attribute_decoded_heap.py',
        'tool/playback_benchmark/decoded-eof-resources-protocol.md',
        'packages/yl_player/example/assets/test_media/format_matrix/mkv-avc-aac.mkv')]
    files.extend(extra_files)
    binaries = [p for p in products.rglob('*') if p.is_file() and
                (p.suffix in ('.dylib','.xctestrun') or p.name in ('yl_player_example','RunnerTests','yl_player_apple'))]
    identity = dict(baseCommit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                    sourceHashes={str(p.relative_to(ROOT)):digest(p) for p in files},
                    binaryHashes={str(p.relative_to(ROOT)):digest(p) for p in binaries})
    (out/'identity.json').write_text(json.dumps(identity,indent=2)+'\n')
    source = out/'sources';source.mkdir()
    for p in files:
        if p.name in ('YlAudioRenderer.swift','YlMacosAudioTests.swift') or p.suffix in ('.py','.md'):
            (source/p.name).write_bytes(p.read_bytes())
    for command,name in [(['sw_vers'],'os.txt'),(['pmset','-g','batt'],'power.txt'),
                         (['system_profiler','SPAudioDataType','-json'],'audio.json'),(['xcodebuild','-version'],'xcode.txt')]:
        with (out/name).open('w') as stream:subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,check=True)
    return identity


def collect(arm, count, directory, decoded=False, decoded_seconds=None, callback_wrapping='wrapped'):
    if callback_wrapping not in ('wrapped','transparent') or (callback_wrapping=='transparent' and not decoded):
        raise ValueError('Transparent callbacks require decoded playback')
    out=Path(directory).resolve();out.mkdir(parents=True,exist_ok=False)
    products=ROOT/'packages/yl_player/example/build/native-macos-tests/Build/Products'
    fixture = None
    extras = []
    if decoded_seconds is not None:
        if not decoded or decoded_seconds not in (4, 30, 60):
            raise ValueError('Decoded length requires --decoded-eof and a supported length')
        fixtures = ROOT/'packages/yl_player/example/build/resource-length-fixtures'
        fixture = fixtures/f'decoded-{decoded_seconds}.mkv'
        extras = [fixtures/f'decoded-{seconds}.mkv' for seconds in (4, 30, 60)] + [
            fixtures/'manifest.json', ROOT/'tool/playback_benchmark/generate_decoded_resource_fixtures.py',
            ROOT/'tool/playback_benchmark/decoded-resource-length-protocol.md',
            ROOT/'tool/playback_benchmark/summarize_decoded_resource_matrix.py',
            ROOT/'tool/playback_benchmark/test_decoded_resource_matrix.py']
    identity=freeze(out,products,extras)
    originals=list(products.glob('*.xctestrun'))
    if len(originals)!=1:raise ValueError('Expected exactly one native test manifest')
    def absolute(value):
        if isinstance(value,str):return value.replace('__TESTROOT__',str(products))
        if isinstance(value,list):return [absolute(x) for x in value]
        if isinstance(value,dict):return {k:absolute(v) for k,v in value.items()}
        return value
    config=absolute(plistlib.loads(originals[0].read_bytes()));target=config['RunnerTests']
    for env in (os.environ,target.get('EnvironmentVariables',{}),target.get('TestingEnvironmentVariables',{})):
        if any(k.startswith('MallocStackLogging') for k in env):raise ValueError('MSL must be disabled')
    target.setdefault('EnvironmentVariables',{}).update(YL_AUDIO_PROBE_KIND='decoded-eof' if decoded else 'resource-drained-'+str(count),YL_AUDIO_PROBE_ARM=arm,YL_AUDIO_PROBE_DIRECTORY=str(out),YL_AUDIO_PROBE_CALLBACK_WRAPPING=callback_wrapping)
    if fixture is not None:
        target['EnvironmentVariables'].update(YL_AUDIO_PROBE_FIXTURE=str(fixture), YL_AUDIO_PROBE_SECONDS=str(decoded_seconds))
    custom=out/'probe.xctestrun';custom.write_bytes(plistlib.dumps(config))
    command=[sys.executable,'-B',str(ROOT/'tool/run_with_display_awake.py'),'xcodebuild','test-without-building','-quiet','-xctestrun',str(custom),
             '-destination','platform=macOS,arch=arm64','-parallel-testing-enabled','NO',
             '-only-testing:RunnerTests/YlMacosAudioTests/' + ('testActualDecodedEOFResourceObservation' if decoded else 'testActualTerminalAdapterContinuousObservation'),
             '-test-timeouts-enabled','YES','-maximum-test-execution-time-allowance','180',
             '-default-test-execution-time-allowance','180','-resultBundlePath',str(out)+'.xcresult']
    (out/'command.json').write_text(json.dumps(command,indent=2)+'\n')
    result=dict(complete=False,arm=arm,buffers=None if decoded else count,decoded=decoded,decodedSeconds=decoded_seconds,callbackWrapping=callback_wrapping,probes=[],errors=[],productionAdmission=False,downstreamBoundProven=False)
    def save():(out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    save();seen=set();offset=0;started=time.monotonic()
    with (out/'xcode.log').open('w') as log:
        proc=subprocess.Popen(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            while proc.poll() is None:
                if time.monotonic()-started>240:raise TimeoutError('Owned test command exceeded240s')
                file=out/'rows.jsonl'
                if file.exists():
                    for line in file.read_text().splitlines()[offset:]:
                        try:row=json.loads(line)
                        except json.JSONDecodeError:break
                        offset+=1;phase=row['phase']
                        if phase not in PHASES or phase in seen:continue
                        seen.add(phase);entry=dict(phase=phase,pid=row['pid'],valid=False)
                        try:
                            actual=subprocess.check_output(['/bin/ps','-p',str(row['pid']),'-o','comm='],text=True,timeout=2).strip()
                            expected=str(products/'Debug/yl_player_example.app/Contents/MacOS/yl_player_example')
                            if actual!=expected:raise ValueError('Unexpected test process identity')
                            if (decoded and not eligible_decoded_checkpoint(row)) or row['nativePlaying'] or (phase!='configured' and row['pending']):
                                raise ValueError('Refusing heap before actual playback drain')
                            entry.update(capture_heap(row['pid'],out/(phase+'-heap.txt')))
                        except (OSError,ValueError,subprocess.SubprocessError) as error:entry['error']=repr(error)
                        finally:
                            result['probes'].append(entry);save();(out/(phase+'.ack')).touch()
                        print(phase,entry['valid'],flush=True)
                time.sleep(.05)
        except (OSError,ValueError,KeyError,subprocess.SubprocessError) as error:
            result['errors'].append(repr(error))
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid,signal.SIGTERM)
                try:proc.wait(timeout=5)
                except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait(timeout=5)
            result['testExitCode']=proc.returncode
            try:
                rows=[json.loads(x) for x in (out/'rows.jsonl').read_text().splitlines()]
                result['observation']=validate_decoded_rows(rows,arm=='candidate',decoded_seconds,fixture.name if fixture else None,callback_wrapping) if decoded else validate_rows(rows,arm=='candidate',count)
                for name,sha in {**identity['sourceHashes'],**identity['binaryHashes']}.items():
                    if digest(ROOT/name)!=sha:raise ValueError('Source/binary changed: '+name)
            except (OSError,ValueError,KeyError,TypeError) as error:result['errors'].append(repr(error))
            result['complete']=proc.returncode==0 and not result['errors'] and [p['phase'] for p in result['probes']]==list(PHASES) and all(p['valid'] for p in result['probes'])
            save()
    return result['complete']


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('arm',choices=['legacy','candidate']);parser.add_argument('buffers',type=int,choices=[1000,2000]);parser.add_argument('directory',type=Path)
    parser.add_argument('--decoded-eof', action='store_true', help='Use the finite decoded file; buffers is ignored')
    parser.add_argument('--decoded-seconds', type=int, choices=[4,30,60], help='Use generated length-control fixture')
    parser.add_argument('--callback-wrapping', choices=['wrapped','transparent'], default='wrapped')
    args=parser.parse_args();sys.exit(0 if collect(args.arm,args.buffers,args.directory,decoded=args.decoded_eof,decoded_seconds=args.decoded_seconds,callback_wrapping=args.callback_wrapping) else 1)

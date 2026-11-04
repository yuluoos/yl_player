"""Exercise two explicitly chosen physical macOS output devices in one public playback."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bound_artifacts import freeze, verify

PHYSICAL = {'bltn', 'usb ', 'blue', 'blea'}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def collect(app, probe, pair, out, mode, av1=False, transport='file'):
    out.mkdir(parents=True, exist_ok=False)
    def snapshot(*args):
        return json.loads(subprocess.check_output([probe, *args]))

    inventory = snapshot('list')
    original = inventory['default']
    devices = {d['id']: d for d in inventory['devices']}
    first, second = pair
    require(first != second and original in pair and all(i in devices and devices[i]['canBeDefault']
            and devices[i]['transport'] in PHYSICAL for i in pair), 'chosen pair is not available')
    other = first if original == second else second
    product = freeze(app)
    result = dict(transport=transport, fixture='qual-av1.mkv' if av1 else 'long_60fps_h264_aac.mkv', mode=mode, reloads=[], inventory=inventory, productSha256=product['sha256'], phases=[], passed=False)
    def save():
        (out/'result.json').write_text(json.dumps(result, indent=2, ensure_ascii=False)+'\n')
    save()
    expected_session = None
    expected_audio = None
    last_state = None
    previous_session = None
    awaiting_failure = False
    attempted_change = False
    with (out/'player.log').open('wb') as log, (out/'observations.jsonl').open('w') as observations:
        proc = subprocess.Popen([app/'Contents/MacOS/yl_player_example'], env=dict(os.environ, YL_ROUTE_TRANSPORT=transport, YL_ROUTE_AV1='1' if av1 else '0'),
                                stdin=subprocess.PIPE, text=True, stdout=log, stderr=log)
        result['pid'] = proc.pid
        try:
            with (out/'player.log').open() as reader:
                def sample():
                    nonlocal last_state, expected_audio, expected_session
                    now = time.monotonic()
                    for line in reader.readlines():
                        if not line.startswith('ROUTE_EVENT '):
                            continue
                        event = json.loads(line.split(' ', 1)[1])
                        if event['kind'] == 'error':
                            raise RuntimeError(event['detail'])
                        if event['kind'] == 'http':
                            result.setdefault('httpLoads', []).append(event)
                        if event['kind'] == 'reload':
                            require(previous_session and event['previous'] == previous_session, 'unexpected reload')
                            result['reloads'].append(event)
                        if event['kind'] != 'state':
                            continue
                        if previous_session and event['session'] == previous_session:
                            continue
                        if event['failure'] is not None:
                            require(awaiting_failure and event['session'] == expected_session
                                    and event['status'] == 'failed' and event['failure'] == 'render.audio_engine_failed',
                                    f'unexpected public failure: {event}')
                            last_state = event
                            continue
                        if av1 and event['status'] == 'playing':
                            require(event['decoder'] == 'software' and event['positionUs'] >= 1170000000,
                                    'expected software AV1 in the qualification fixture tail')
                        if expected_session is None:
                            expected_session = event['session']
                            if expected_audio is None:
                                expected_audio = event['audio']
                            require(expected_session and len(expected_audio) == 1, 'missing selected audio or session')
                        require((event['session'], event['audio']) == (expected_session, expected_audio),
                                'session or selected track changed')
                        if last_state is not None:
                            require(event['positionUs'] >= last_state['positionUs'], 'public position moved backwards')
                        last_state = event
                    state = snapshot('process', str(proc.pid))
                    row = dict(hostSeconds=now, **state, public=last_state)
                    observations.write(json.dumps(row)+'\n')
                    observations.flush()
                    return row

                def phase(label, target, deadline_seconds):
                    deadline = time.monotonic() + deadline_seconds
                    start = None
                    while time.monotonic() < deadline and proc.poll() is None:
                        row = sample()
                        public = row['public']
                        if (row['default'] == target and row['runningOutput'] and row['outputDevices'] == [target]
                                and public and public['status'] == 'playing' and public['positionUs'] >= 1000000):
                            if start is None:
                                start = row
                            if (row['hostSeconds'] - start['hostSeconds'] >= 1 and
                                    public['positionUs'] - start['public']['positionUs'] >= 900000):
                                result['phases'].append(dict(label=label, id=target, start=start, end=row))
                                save()
                                return
                        else:
                            start = None
                        time.sleep(.12)
                    raise RuntimeError(f'{label}: no sustained process output and playback progress on device {target}')

                phase('original', original, 20)
                attempted_change = True
                for label, target in [('alternate', other), ('returned', original)]:
                    awaiting_failure = mode == 'failure-reload'
                    subprocess.run([probe, 'set', str(target)], check=True)
                    if mode != 'same-session':
                        deadline = time.monotonic() + 15
                        while time.monotonic() < deadline:
                            row = sample()
                            if (row['default'] == target and not row['runningOutput']
                                    and (not awaiting_failure or last_state['status'] == 'failed')):
                                break
                            time.sleep(.12)
                        else:
                            raise RuntimeError(f'{label}: expected route interruption was not observed')
                        result.setdefault('interruptions', []).append(row)
                        awaiting_failure = False
                        previous_session, expected_session, last_state = expected_session, None, None
                        proc.stdin.write('reload\n')
                        proc.stdin.flush()
                    phase(label, target, 18)
                result['exit'] = proc.wait(timeout=85)
                result['completed'] = any('"status":"completed"' in line for line in (out/'player.log').read_text().splitlines())
                require(result['exit'] == 0 and result['completed'], 'playback did not complete naturally')
                if transport == 'http':
                    sessions = [p['start']['public']['session'] for p in result['phases']]
                    loads = result.get('httpLoads', [])
                    require([e['session'] for e in loads if e['ranges']] == list(dict.fromkeys(sessions)),
                            'missing per-session HTTP range receipt')
                require(verify(app, product), 'app changed during playback')

        except Exception as error:
            result['error'] = str(error)
        finally:
            try:
                if attempted_change and snapshot('list')['default'] != original:
                    subprocess.run([probe, 'set', str(original)], check=True)
                restored = snapshot('list')['default']
                result['finalDefault'] = restored
                require(restored == original, 'original output was not restored')
                result['passed'] = 'error' not in result and result.get('completed') is True
            except Exception as error:
                result['restorationError'] = str(error)
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=10)
                save()
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('app','probe','out'):
        parser.add_argument(key, type=Path)
    parser.add_argument('--devices', nargs=2, type=int, required=True)
    parser.add_argument('--mode', choices=('same-session', 'explicit-reload', 'failure-reload'), default='same-session')
    parser.add_argument('--av1', action='store_true', help='Use the qualified AV1/Opus fixture')
    parser.add_argument('--transport', choices=('file', 'http'), default='file')
    args = parser.parse_args()
    result = collect(args.app.resolve(), args.probe.resolve(), args.devices, args.out, args.mode, args.av1, args.transport)
    print(json.dumps({k: result.get(k) for k in ('passed','error','finalDefault','completed')}))
    sys.exit(0 if result['passed'] else 1)

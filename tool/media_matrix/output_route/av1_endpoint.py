"""Observe the public AV1 verification host on its physical default output."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bound_artifacts import freeze, sha_file


def evaluate(events, samples, device):
    times = {e['line']: e['ns'] for e in events}
    windows = []
    for transport in ('file', 'http'):
        def mark(prefix):
            return next(ns for line, ns in times.items() if line.startswith(prefix))

        playback = next(e for e in events if e['line'].startswith('PUBLIC_PLAYBACK ')
                        and json.loads(e['line'].split(' ', 1)[1])['transport'] == transport)
        intervals = [('play', times[f'PUBLIC_STEP {transport} play'],
                      times[f'PUBLIC_STEP {transport} pause-seek-2000'])]
        for target in (2000, 1250, 0):
            intervals.append((f'seek-{target}', mark(f'PUBLIC_SEEK_RETURN {transport} target={target} '),
                              mark(f'PUBLIC_SEEK_WAIT {transport} target={target} ')))
        intervals.append(('until-completed', times[f'PUBLIC_STEP {transport} await-completed'], playback['ns']))
        for phase, start, end in intervals:
            rows = [r for r in samples if start <= r['startNs'] and r['endNs'] <= end]
            active = [r for r in rows if r['runningOutput']]
            if not active or any(r['default'] != device for r in rows) or any(
                    r['outputDevices'] != [device] for r in active):
                raise ValueError(f'{transport}/{phase}: no confirmed exclusive output to the selected device')
            windows.append(dict(transport=transport, phase=phase, samples=len(rows), active=len(active)))
    return windows


def collect(app, probe, out):
    out.mkdir(parents=True, exist_ok=False)
    inventory = json.loads(subprocess.check_output([probe, 'list']))
    device = inventory['default']
    endpoint = next(d for d in inventory['devices'] if d['id'] == device)
    if endpoint['transport'] not in ('bltn', 'usb ', 'blue', 'blea'):
        raise ValueError('physical default output required')
    profile = app/'Contents/Resources/yl-player-qualified-av1.json'
    result = dict(endpoint=endpoint, productSha256=freeze(app)['sha256'], profileSha256=sha_file(profile),
                  profileKey=json.loads(profile.read_bytes())['key'], passed=False)
    events, samples = [], []
    env = dict(os.environ, YL_AV1_PHASE='production', NSUnbufferedIO='YES')
    proc = subprocess.Popen([app/'Contents/MacOS/yl_player_example'], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    result['pid'] = proc.pid

    def read_events():
        for line in proc.stdout:
            if line.startswith('PUBLIC_'):
                events.append(dict(ns=time.monotonic_ns(), line=line.rstrip()))

    reader = threading.Thread(target=read_events)
    reader.start()
    try:
        deadline = time.monotonic() + 90
        while proc.poll() is None:
            if time.monotonic() >= deadline:
                raise TimeoutError('public playback exceeded 90 seconds')
            start = time.monotonic_ns()
            response = subprocess.run([probe, 'process', str(proc.pid)], capture_output=True, text=True)
            if response.returncode and proc.poll() is not None:
                break
            response.check_returncode()
            samples.append(dict(startNs=start, endNs=time.monotonic_ns(), **json.loads(response.stdout)))
            time.sleep(.04)
        reader.join()
        if proc.returncode or not any(e['line'] == 'PUBLIC_FINISH 0' for e in events):
            raise ValueError('public playback did not pass')
        result['windows'] = evaluate(events, samples, device)
        result['passed'] = True
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=10)
        reader.join()
        for name, data in [('events', events), ('samples', samples), ('result', result)]:
            (out/f'{name}.json').write_text(json.dumps(data, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(result['windows']))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ('app', 'probe', 'out'):
        parser.add_argument(key, type=Path)
    args = parser.parse_args()
    collect(args.app.resolve(), args.probe.resolve(), args.out)

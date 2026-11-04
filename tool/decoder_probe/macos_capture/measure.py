"""Capture one frozen Release example process; only a passing baseline freezes limits."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from macos_profile import LIMIT_NAMES, freeze_limits, observations


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def files(app):
    return {str(p.relative_to(app)): digest(p) for p in sorted(app.rglob('*'))
            if p.is_file() and not p.is_symlink()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('root', type=Path)
    parser.add_argument('phase', choices=('baseline', 'verification'))
    args = parser.parse_args()
    app, root, phase = args.app.resolve(), args.root.resolve(), args.phase
    protocol = json.loads((root/'protocol.json').read_text())
    product = files(app)
    assert product[protocol['fixturePath']] == protocol['fixtureSha256']
    plan = dict(product=product, protocolSha256=digest(root/'protocol.json'), run=phase)
    env = {**os.environ, 'NSUnbufferedIO': 'YES', 'YL_AV1_VISIBLE_QUALIFICATION': '1', 'YL_AV1_PHASE': phase}
    env.pop('YL_TRIAL_LIMITS', None)
    if phase == 'verification':
        baseline = json.loads((root/'baseline/receipt.json').read_text())
        assert baseline['passed'] and baseline['product'] == product
        assert baseline['protocolSha256'] == plan['protocolSha256']
        plan['limitsSha256'] = digest(root/'baseline/limits.json')
        env['YL_TRIAL_LIMITS'] = (root/'baseline/limits.json').read_text()
    out = root/phase
    out.mkdir()
    save(out/'plan.json', plan)
    started = time.monotonic()
    with (out/'raw.log').open('x') as log:
        process = subprocess.Popen([str(app/'Contents/MacOS/yl_player_example')],
                                   env=env, stdout=log, stderr=log)
        (out/'pid').write_text(str(process.pid))
        awake = subprocess.Popen(['/usr/bin/caffeinate', '-d', '-i', '-u', '-t', '1350', '-w', str(process.pid)])
        try:
            code = process.wait(timeout=1350)
        except subprocess.TimeoutExpired:
            process.terminate()
            code = process.wait(timeout=10)
        finally:
            awake.wait(timeout=10)
    lines = [line[line.index('QUAL_'):] for line in (out/'raw.log').read_text().splitlines() if 'QUAL_' in line]
    rows = [line.split()[-5:] for line in lines if line.startswith(('QUAL_SAMPLE ', 'QUAL_END '))]
    peaks = dict(zip(LIMIT_NAMES, (max(int(row[i]) for row in rows) for i in range(5)))) if rows else {}
    receipt = dict(plan, pid=process.pid, exit=code, elapsedSeconds=time.monotonic()-started,
                   peaks=peaks, passed=code == 0, errors=[])
    save(out/'receipt.json', receipt)
    try:
        observations(out, phase, protocol['expectedVideoPackets'])
        assert files(app) == product, 'frozen app changed during capture'
        if phase == 'baseline':
            limits = freeze_limits(peaks, protocol)
    except (ValueError, KeyError, AssertionError) as error:
        receipt.update(passed=False, errors=[str(error)])
        save(out/'receipt.json', receipt)
    if receipt['passed'] and phase == 'baseline':
        save(out/'limits.json', limits)
    print(json.dumps({k: receipt[k] for k in ('passed', 'exit', 'elapsedSeconds', 'peaks', 'errors')}, indent=2), flush=True)
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
